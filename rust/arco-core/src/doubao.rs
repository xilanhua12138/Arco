use chrono::{Local, TimeZone};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use futures_util::{Sink, SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::AsyncReadExt;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::Message;

use crate::models::{LiveTranscriptLine, LiveTranscriptSnapshot};

const ENDPOINT: &str = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async";
const RESOURCE_ID: &str = "volc.seedasr.sauc.duration";
const SAMPLE_RATE: usize = 16_000;
const STEREO_FRAME_BYTES: usize = 4;
const MONO_FRAME_BYTES: usize = 2;
const READ_CHUNK_BYTES: usize = 12_800;
const MEETING_END_WINDOW_MS: usize = 800;
const MIN_SPEECH_BEFORE_ENDPOINT_MS: usize = 1_000;
const AUDIO_CHUNKS_PER_SECOND: usize = SAMPLE_RATE * STEREO_FRAME_BYTES / READ_CHUNK_BYTES;
const DEFAULT_BUFFER_SECONDS: usize = 60;
const SPEAKER_TIMELINE_WAIT: Duration = Duration::from_millis(1_500);
const MAX_REPLAY_RATE_NUMERATOR: u128 = 5;
const MAX_REPLAY_RATE_DENOMINATOR: u128 = 4;
const LIVE_AUDIO_SEND_TIMEOUT: Duration = Duration::from_secs(3);
const LIVE_RESPONSE_TIMEOUT: Duration = Duration::from_secs(12);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(5);
const SPEECH_RMS_THRESHOLD: f64 = 0.01;
const FINAL_ACK_TIMEOUT: Duration = Duration::from_secs(5);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const EOF_FINALIZATION_TIMEOUT: Duration = FINAL_ACK_TIMEOUT;
const MAX_PENDING_TRANSCRIPT_SEGMENTS: usize = 10_000;
const FATAL_ERROR_PREFIX: &str = "ARCO_DOUBAO_FATAL:";

type DoubaoSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Clone, Debug, PartialEq, Eq)]
struct AudioChunk {
    data: Vec<u8>,
    start_frame: usize,
}

impl AudioChunk {
    fn end_frame(&self) -> usize {
        self.start_frame + self.data.len() / MONO_FRAME_BYTES
    }

    fn is_digital_silence(&self) -> bool {
        !self.data.is_empty() && self.data.iter().all(|byte| *byte == 0)
    }

    fn has_speech_energy(&self) -> bool {
        let mut sample_count = 0usize;
        let mut squared_sum = 0.0f64;
        for bytes in self.data.chunks_exact(MONO_FRAME_BYTES) {
            let sample = i16::from_le_bytes([bytes[0], bytes[1]]) as f64 / i16::MAX as f64;
            squared_sum += sample * sample;
            sample_count += 1;
        }
        sample_count > 0 && (squared_sum / sample_count as f64).sqrt() >= SPEECH_RMS_THRESHOLD
    }
}

#[derive(Default)]
struct PendingAudio {
    chunks: VecDeque<AudioChunk>,
}

impl PendingAudio {
    fn restore(&mut self, chunk: AudioChunk) {
        self.chunks.push_front(chunk);
    }

    fn take(&mut self) -> Option<AudioChunk> {
        self.chunks.pop_front()
    }

    fn bytes(&self) -> usize {
        self.chunks.iter().map(|chunk| chunk.data.len()).sum()
    }

    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct SentAudio {
    sequence: i32,
    chunk: AudioChunk,
    final_packet: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct AudioConfirmation {
    confirmed_chunks: usize,
    final_confirmed: bool,
    confirmed_through_frame: Option<usize>,
}

impl AudioConfirmation {
    fn absorb(&mut self, other: Self) {
        self.confirmed_chunks += other.confirmed_chunks;
        self.final_confirmed |= other.final_confirmed;
        self.confirmed_through_frame = self
            .confirmed_through_frame
            .max(other.confirmed_through_frame);
    }
}

#[derive(Default)]
struct InFlightAudio {
    chunks: VecDeque<SentAudio>,
}

impl InFlightAudio {
    fn record(&mut self, sequence: i32, chunk: AudioChunk, final_packet: bool) {
        debug_assert!(sequence > 0);
        self.chunks.push_back(SentAudio {
            sequence,
            chunk,
            final_packet,
        });
    }

    fn confirm_through(&mut self, sequence: i32) -> AudioConfirmation {
        let watermark = sequence.checked_abs().unwrap_or(i32::MAX);
        let mut confirmation = AudioConfirmation::default();
        while self
            .chunks
            .front()
            .is_some_and(|sent| sent.sequence <= watermark)
        {
            if self.chunks.front().is_some_and(|sent| sent.final_packet) {
                break;
            }
            let sent = self
                .chunks
                .pop_front()
                .expect("front was checked before removing confirmed audio");
            confirmation.confirmed_chunks += 1;
            confirmation.confirmed_through_frame = confirmation
                .confirmed_through_frame
                .max(Some(sent.chunk.end_frame()));
        }
        confirmation
    }

    fn confirm_through_frame(&mut self, frame: usize) -> AudioConfirmation {
        let mut confirmation = AudioConfirmation::default();
        while self
            .chunks
            .front()
            .is_some_and(|sent| !sent.final_packet && sent.chunk.end_frame() <= frame)
        {
            let sent = self
                .chunks
                .pop_front()
                .expect("front was checked before removing persisted audio");
            confirmation.confirmed_chunks += 1;
            confirmation.confirmed_through_frame = confirmation
                .confirmed_through_frame
                .max(Some(sent.chunk.end_frame()));
        }
        confirmation
    }

    fn confirm_explicit_final(&mut self) -> AudioConfirmation {
        if !self.chunks.iter().any(|sent| sent.final_packet) {
            return AudioConfirmation::default();
        }
        let mut confirmation = AudioConfirmation::default();
        while let Some(sent) = self.chunks.pop_front() {
            confirmation.confirmed_chunks += 1;
            confirmation.final_confirmed |= sent.final_packet;
            confirmation.confirmed_through_frame = confirmation
                .confirmed_through_frame
                .max(Some(sent.chunk.end_frame()));
        }
        confirmation.final_confirmed = true;
        confirmation
    }

    fn restore_into(&mut self, pending: &mut PendingAudio) {
        while let Some(sent) = self.chunks.pop_back() {
            pending.restore(sent.chunk);
        }
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.chunks.len()
    }

    fn is_empty(&self) -> bool {
        self.chunks.is_empty()
    }

    fn contains_final_packet(&self) -> bool {
        self.chunks.iter().any(|sent| sent.final_packet)
    }
}

struct ReplayPacer {
    origin_end_frame: usize,
}

impl ReplayPacer {
    fn new(first: &AudioChunk) -> Self {
        Self {
            origin_end_frame: first.end_frame(),
        }
    }

    fn delay_for(&self, chunk: &AudioChunk, elapsed: Duration) -> Duration {
        let replay_frames = chunk.end_frame().saturating_sub(self.origin_end_frame) as u128;
        let target_nanos = replay_frames
            .saturating_mul(1_000_000_000)
            .saturating_mul(MAX_REPLAY_RATE_DENOMINATOR)
            / ((SAMPLE_RATE as u128).saturating_mul(MAX_REPLAY_RATE_NUMERATOR));
        Duration::from_nanos(target_nanos.min(u64::MAX as u128) as u64).saturating_sub(elapsed)
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum ServerMessage {
    Result {
        sequence: Option<i32>,
        is_final: bool,
        payload: Value,
    },
    Acknowledgement {
        sequence: i32,
    },
    Error {
        code: u32,
        message: String,
    },
}

#[derive(Clone, Debug)]
struct Segment {
    channel: usize,
    speaker: i64,
    label: String,
    text: String,
    start: f64,
    end: f64,
}

#[derive(Default)]
struct SpeakerRegistry {
    ids: HashMap<(u64, i64), i64>,
    next: i64,
}

impl SpeakerRegistry {
    fn relabel(&mut self, mut segment: Segment, connection_id: u64) -> Segment {
        let speaker = *self
            .ids
            .entry((connection_id, segment.speaker))
            .or_insert_with(|| {
                let speaker = self.next;
                self.next = self.next.saturating_add(1);
                speaker
            });
        segment.speaker = speaker;
        segment.label = format!(
            "{} {}",
            if segment.channel == 0 {
                "Remote"
            } else {
                "In room"
            },
            speaker + 1,
        );
        segment
    }
}

struct TranscriptWriter {
    path: PathBuf,
    live_path: PathBuf,
    session_started_at: f64,
    active_channels: [bool; 2],
    processed_until: [f64; 2],
    pending: Vec<Segment>,
    live_lines: [Vec<LiveTranscriptLine>; 2],
}

impl TranscriptWriter {
    fn new(path: PathBuf, session_started_at: f64) -> Result<Self, String> {
        if !path.exists() {
            return Err(
                "The desktop host must initialize the transcript before transcription".into(),
            );
        }
        let live_path = crate::meetings::live_transcript_path(&path);
        match fs::remove_file(&live_path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "could not reset live Doubao transcript {}: {error}",
                    live_path.display()
                ));
            }
        }
        Ok(Self {
            path,
            live_path,
            session_started_at,
            active_channels: [true, true],
            processed_until: [0.0, 0.0],
            pending: Vec::new(),
            live_lines: [Vec::new(), Vec::new()],
        })
    }

    fn set_active_channels(&mut self, active: [bool; 2]) {
        self.active_channels = active;
        for (channel, enabled) in active.into_iter().enumerate() {
            if !enabled {
                self.processed_until[channel] = f64::INFINITY;
            }
        }
    }

    fn append(&mut self, segment: &Segment) -> Result<(), String> {
        if self.pending.len() >= MAX_PENDING_TRANSCRIPT_SEGMENTS {
            return Err(format!(
                "Doubao transcript reorder buffer exceeded {MAX_PENDING_TRANSCRIPT_SEGMENTS} segments"
            ));
        }
        self.pending.push(segment.clone());
        self.flush_ready()
    }

    fn update_live(&mut self, channel: usize, segments: &[Segment]) -> Result<(), String> {
        let channel = channel.min(1);
        self.live_lines[channel] = segments
            .iter()
            .map(|segment| {
                let seconds = self.session_started_at + segment.start;
                let timestamp = Local
                    .timestamp_opt(seconds as i64, 0)
                    .single()
                    .unwrap_or_else(Local::now)
                    .format("%H:%M:%S")
                    .to_string();
                LiveTranscriptLine {
                    id: format!(
                        "doubao-live-{}-{}",
                        segment.channel,
                        (segment.start * 1_000.0).round() as i64
                    ),
                    timestamp,
                    speaker: segment.label.clone(),
                    text: segment.text.clone(),
                }
            })
            .collect();
        self.persist_live_snapshot()
    }

    fn clear_live(&mut self) -> Result<(), String> {
        self.live_lines = [Vec::new(), Vec::new()];
        self.persist_live_snapshot()
    }

    fn persist_live_snapshot(&self) -> Result<(), String> {
        let mut lines = self
            .live_lines
            .iter()
            .flatten()
            .cloned()
            .collect::<Vec<_>>();
        lines.sort_by(|left, right| {
            left.timestamp
                .cmp(&right.timestamp)
                .then_with(|| left.id.cmp(&right.id))
        });
        if lines.is_empty() {
            return match fs::remove_file(&self.live_path) {
                Ok(()) => Ok(()),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
                Err(error) => Err(format!(
                    "could not clear live Doubao transcript {}: {error}",
                    self.live_path.display()
                )),
            };
        }
        let payload = serde_json::to_vec(&LiveTranscriptSnapshot { lines })
            .map_err(|error| format!("could not encode live Doubao transcript: {error}"))?;
        let temporary = PathBuf::from(format!("{}.tmp", self.live_path.display()));
        fs::write(&temporary, payload).map_err(|error| {
            format!(
                "could not write live Doubao transcript {}: {error}",
                temporary.display()
            )
        })?;
        fs::rename(&temporary, &self.live_path).map_err(|error| {
            format!(
                "could not publish live Doubao transcript {}: {error}",
                self.live_path.display()
            )
        })
    }

    fn advance(&mut self, channel: usize, processed_until: f64) -> Result<(), String> {
        let channel = channel.min(1);
        self.processed_until[channel] = self.processed_until[channel].max(processed_until);
        self.flush_ready()
    }

    fn advance_from_confirmation(
        &mut self,
        channel: usize,
        confirmation: &AudioConfirmation,
    ) -> Result<(), String> {
        let Some(frame) = confirmation.confirmed_through_frame else {
            return Ok(());
        };
        self.advance(channel, frame as f64 / SAMPLE_RATE as f64)
    }

    fn complete_channel(&mut self, channel: usize) -> Result<(), String> {
        self.processed_until[channel.min(1)] = f64::INFINITY;
        self.flush_ready()
    }

    fn flush_ready(&mut self) -> Result<(), String> {
        let cutoff = self
            .processed_until
            .iter()
            .enumerate()
            .filter(|(channel, _)| self.active_channels[*channel])
            .map(|(_, value)| *value)
            .fold(f64::INFINITY, f64::min);
        self.flush_through(cutoff)
    }

    fn flush_all(&mut self) -> Result<(), String> {
        self.flush_through(f64::INFINITY)
    }

    fn flush_through(&mut self, cutoff: f64) -> Result<(), String> {
        self.pending.sort_by(|left, right| {
            left.start
                .total_cmp(&right.start)
                .then_with(|| left.end.total_cmp(&right.end))
                .then_with(|| left.channel.cmp(&right.channel))
                .then_with(|| left.speaker.cmp(&right.speaker))
                .then_with(|| left.text.cmp(&right.text))
        });
        let ready = self
            .pending
            .iter()
            .take_while(|segment| segment.end <= cutoff)
            .count();
        let segments: Vec<_> = self.pending.drain(..ready).collect();
        for segment in segments {
            self.append_to_file(&segment)?;
        }
        Ok(())
    }

    fn append_to_file(&self, segment: &Segment) -> Result<(), String> {
        let mut file = OpenOptions::new()
            .append(true)
            .open(&self.path)
            .map_err(|error| {
                format!("could not open transcript {}: {error}", self.path.display())
            })?;
        let seconds = self.session_started_at + segment.start;
        let timestamp = Local
            .timestamp_opt(seconds as i64, 0)
            .single()
            .unwrap_or_else(Local::now)
            .format("%H:%M:%S");
        writeln!(file, "**[{timestamp}] {}:** {}\n", segment.label, segment.text)
            .and_then(|_| {
                writeln!(
                    file,
                    "<!-- arco channel={} speaker={} stream=doubao-bigmodel start={:.3} end={:.3} -->\n",
                    segment.channel, segment.speaker, segment.start, segment.end,
                )
            })
            .and_then(|_| file.flush())
            .map_err(|error| format!("could not write live Doubao transcript: {error}"))
    }
}

pub fn credential_headers(
    app_id: &str,
    access_token: &str,
    request_id: &str,
) -> Result<HashMap<&'static str, String>, String> {
    let app_id = app_id.trim();
    let access_token = access_token.trim();
    if app_id.is_empty() {
        return Err("A Doubao API Key or App ID is required.".into());
    }
    if app_id.chars().any(char::is_whitespace)
        || access_token.chars().any(char::is_whitespace)
        || request_id.chars().any(char::is_whitespace)
    {
        return Err("Doubao credentials and request IDs cannot contain spaces.".into());
    }
    let mut headers = HashMap::from([
        ("X-Api-Resource-Id", RESOURCE_ID.to_string()),
        ("X-Api-Request-Id", request_id.to_string()),
    ]);
    if access_token.is_empty() {
        headers.insert("X-Api-Key", app_id.to_string());
    } else {
        headers.insert("X-Api-App-Key", app_id.to_string());
        headers.insert("X-Api-Access-Key", access_token.to_string());
    }
    Ok(headers)
}

fn gzip(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(data)
        .map_err(|error| format!("could not compress Doubao request: {error}"))?;
    encoder
        .finish()
        .map_err(|error| format!("could not finish Doubao request compression: {error}"))
}

fn gunzip(data: &[u8]) -> Result<Vec<u8>, String> {
    let mut decoder = GzDecoder::new(data);
    let mut result = Vec::new();
    decoder
        .read_to_end(&mut result)
        .map_err(|error| format!("could not decompress Doubao response: {error}"))?;
    Ok(result)
}

pub fn encode_full_client_request(
    request_id: &str,
    language: &str,
    enable_speaker_info: bool,
) -> Result<Vec<u8>, String> {
    match language {
        "zh-CN" | "en-US" | "auto" => {}
        other => return Err(format!("unsupported Doubao recognition language: {other}")),
    }
    let mut request = json!({
        "user": { "uid": request_id },
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": SAMPLE_RATE,
            "bits": 16,
            "channel": 1
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_punc": true,
            "show_utterances": true,
            "enable_speaker_info": enable_speaker_info,
            "enable_nonstream": true,
            "end_window_size": MEETING_END_WINDOW_MS,
            "force_to_speech_time": MIN_SPEECH_BEFORE_ENDPOINT_MS,
            "result_type": "full"
        }
    });
    if enable_speaker_info {
        request["request"]["ssd_version"] = Value::String("200".into());
    }
    let payload = gzip(
        &serde_json::to_vec(&request)
            .map_err(|error| format!("could not encode Doubao request: {error}"))?,
    )?;
    // The SAUC full request starts at sequence 1; ordinary audio continues at
    // 2. Optimized Result sequences describe result changes, not input ACKs.
    let mut packet = vec![0x11, 0x11, 0x11, 0x00];
    packet.extend_from_slice(&1i32.to_be_bytes());
    packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    packet.extend_from_slice(&payload);
    Ok(packet)
}

pub fn encode_audio_request(sequence: i32, audio: &[u8]) -> Result<Vec<u8>, String> {
    if sequence <= 0 {
        return Err("Doubao audio request sequence must be positive.".into());
    }
    let payload = gzip(audio)?;
    let mut packet = vec![0x11, 0x21, 0x01, 0x00];
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    packet.extend_from_slice(&payload);
    Ok(packet)
}

pub fn encode_audio_flush_request() -> Result<Vec<u8>, String> {
    let payload = gzip(&[])?;
    // Mizzen's validated optimized two-pass path sends EOF as a separate,
    // gzip-compressed empty LAST_NO_SEQ packet after all real audio.
    let mut packet = vec![0x11, 0x22, 0x01, 0x00];
    packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    packet.extend_from_slice(&payload);
    Ok(packet)
}

fn read_u32(packet: &[u8], offset: &mut usize) -> Result<u32, String> {
    let bytes: [u8; 4] = packet
        .get(*offset..*offset + 4)
        .ok_or_else(|| "truncated Doubao response".to_string())?
        .try_into()
        .map_err(|_| "truncated Doubao response".to_string())?;
    *offset += 4;
    Ok(u32::from_be_bytes(bytes))
}

fn read_i32(packet: &[u8], offset: &mut usize) -> Result<i32, String> {
    Ok(read_u32(packet, offset)? as i32)
}

fn read_payload(packet: &[u8], offset: &mut usize) -> Result<Vec<u8>, String> {
    let size = read_u32(packet, offset)? as usize;
    let payload = packet
        .get(*offset..*offset + size)
        .ok_or_else(|| "truncated Doubao response payload".to_string())?;
    *offset += size;
    Ok(payload.to_vec())
}

pub fn decode_server_message(packet: &[u8]) -> Result<ServerMessage, String> {
    if packet.len() < 4 {
        return Err("truncated Doubao response header".into());
    }
    if packet[0] >> 4 != 1 {
        return Err(format!(
            "unsupported Doubao protocol version: {}",
            packet[0] >> 4
        ));
    }
    let header_size = (packet[0] & 0x0f) as usize * 4;
    if header_size < 4 || packet.len() < header_size {
        return Err("invalid Doubao response header size".into());
    }
    let message_type = packet[1] >> 4;
    let flags = packet[1] & 0x0f;
    let serialization = packet[2] >> 4;
    let compression = packet[2] & 0x0f;
    let mut offset = header_size;
    match message_type {
        9 => {
            let sequence = if flags & 0x01 != 0 {
                Some(read_i32(packet, &mut offset)?)
            } else {
                None
            };
            let mut payload = read_payload(packet, &mut offset)?;
            if compression == 1 {
                payload = gunzip(&payload)?;
            } else if compression != 0 {
                return Err(format!(
                    "unsupported Doubao response compression: {compression}"
                ));
            }
            let payload = if serialization == 1 {
                serde_json::from_slice(&payload)
                    .map_err(|error| format!("invalid Doubao JSON response: {error}"))?
            } else {
                Value::String(String::from_utf8_lossy(&payload).into_owned())
            };
            Ok(ServerMessage::Result {
                sequence,
                is_final: flags & 0x02 != 0 || sequence.is_some_and(|value| value < 0),
                payload,
            })
        }
        11 => Ok(ServerMessage::Acknowledgement {
            sequence: read_i32(packet, &mut offset)?,
        }),
        15 => {
            let code = read_u32(packet, &mut offset)?;
            let mut payload = read_payload(packet, &mut offset)?;
            if compression == 1 {
                payload = gunzip(&payload)?;
            }
            let message = String::from_utf8(payload)
                .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned());
            Ok(ServerMessage::Error { code, message })
        }
        other => Err(format!("unsupported Doubao response type: {other}")),
    }
}

pub fn split_stereo_pcm(data: &[u8]) -> Result<(Vec<u8>, Vec<u8>), String> {
    if data.len() % STEREO_FRAME_BYTES != 0 {
        return Err("stereo PCM ended on an incomplete frame".into());
    }
    let frames = data.len() / STEREO_FRAME_BYTES;
    let mut remote = Vec::with_capacity(frames * 2);
    let mut room = Vec::with_capacity(frames * 2);
    for frame in data.chunks_exact(STEREO_FRAME_BYTES) {
        remote.extend_from_slice(&frame[..2]);
        room.extend_from_slice(&frame[2..]);
    }
    Ok((remote, room))
}

fn provider_milliseconds(value: Option<&Value>) -> Option<f64> {
    value
        .and_then(|value| {
            value
                .as_f64()
                .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
        })
        .filter(|value| value.is_finite() && *value >= 0.0)
}

fn segments_from_payload(payload: &Value, channel: usize, include_tentative: bool) -> Vec<Segment> {
    let utterances = payload
        .get("result")
        .and_then(|value| value.get("utterances"))
        .or_else(|| payload.get("utterances"))
        .and_then(Value::as_array);
    let Some(utterances) = utterances else {
        return Vec::new();
    };
    utterances
        .iter()
        .filter(|utterance| {
            include_tentative
                || utterance
                    .get("definite")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
        })
        .filter_map(|utterance| {
            let text = utterance.get("text")?.as_str()?.trim();
            if text.is_empty() {
                return None;
            }
            // Timing is metadata, not a validity check for recognized text.
            // The optimized endpoint can omit it on an early definite result
            // or serialize it as a string.
            let start_ms = provider_milliseconds(
                utterance
                    .get("start_time")
                    .or_else(|| utterance.get("startTime")),
            )
            .unwrap_or(0.0);
            let end_ms = provider_milliseconds(
                utterance
                    .get("end_time")
                    .or_else(|| utterance.get("endTime")),
            )
            .unwrap_or(start_ms);
            let start = start_ms / 1_000.0;
            let end = end_ms / 1_000.0;
            let additions = utterance.get("additions");
            let speaker = additions
                .and_then(|value| value.get("speaker_id"))
                .and_then(provider_integer)
                .map(|speaker| speaker.max(0))
                .or_else(|| {
                    additions
                        .and_then(|value| value.get("speaker"))
                        .and_then(provider_integer)
                        .map(|speaker| speaker.saturating_sub(1).max(0))
                })
                .unwrap_or(0);
            Some(Segment {
                channel,
                speaker,
                label: format!(
                    "{} {}",
                    if channel == 0 { "Remote" } else { "In room" },
                    speaker + 1,
                ),
                text: text.into(),
                start,
                end: end.max(start),
            })
        })
        .collect()
}

fn provider_integer(value: &Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|text| text.parse().ok()))
}

fn segments_from_connection_payload(
    payload: &Value,
    channel: usize,
    include_tentative: bool,
    connection_origin: f64,
) -> Vec<Segment> {
    segments_from_payload(payload, channel, include_tentative)
        .into_iter()
        .map(|mut segment| {
            segment.start += connection_origin;
            segment.end += connection_origin;
            segment
        })
        .collect()
}

fn segment_dedup_key(segment: &Segment) -> (i64, i64, String) {
    (
        (segment.start * 1_000.0) as i64,
        (segment.end * 1_000.0) as i64,
        segment.text.clone(),
    )
}

fn audio_buffer_capacity(seconds: Option<usize>) -> usize {
    seconds
        .unwrap_or(DEFAULT_BUFFER_SECONDS)
        .clamp(1, 300)
        .saturating_mul(AUDIO_CHUNKS_PER_SECOND)
}

fn next_retry_delay(current: u64) -> u64 {
    current.saturating_mul(2).min(15)
}

fn is_fatal_channel_error(error: &str) -> bool {
    let lowercase = error.to_ascii_lowercase();
    error.starts_with(FATAL_ERROR_PREFIX)
        || error.contains("Doubao transcription failed (")
        || error.contains("unsupported Doubao recognition language")
        || error.contains("invalid Doubao request")
        || error.contains("Doubao readiness coordinator stopped")
        || (lowercase.contains("http") && (lowercase.contains("401") || lowercase.contains("403")))
}

fn apply_server_confirmation(
    message: &ServerMessage,
    in_flight: &mut InFlightAudio,
    allow_final_confirmation: bool,
) -> AudioConfirmation {
    match message {
        ServerMessage::Acknowledgement { sequence } => in_flight.confirm_through(*sequence),
        ServerMessage::Result { is_final, .. }
            if *is_final && allow_final_confirmation && in_flight.contains_final_packet() =>
        {
            in_flight.confirm_explicit_final()
        }
        ServerMessage::Result { .. } => AudioConfirmation::default(),
        ServerMessage::Error { .. } => AudioConfirmation::default(),
    }
}

fn response_audio_duration_ms(payload: &Value) -> Option<f64> {
    payload
        .get("audio_info")
        .and_then(|value| value.get("duration"))
        .or_else(|| {
            payload
                .get("result")
                .and_then(|value| value.get("audio_info"))
                .and_then(|value| value.get("duration"))
        })
        .and_then(Value::as_f64)
}

fn finalization_deadline(started: tokio::time::Instant) -> tokio::time::Instant {
    started + EOF_FINALIZATION_TIMEOUT
}

fn buffered_audio_seconds(pending: &PendingAudio, receiver: &mpsc::Receiver<AudioChunk>) -> f64 {
    let bytes = pending.bytes() + receiver.len() * (READ_CHUNK_BYTES / 2);
    bytes as f64 / (SAMPLE_RATE * MONO_FRAME_BYTES) as f64
}

async fn attribute_segment(mut segment: Segment, timeline: Option<&Path>) -> Segment {
    let Some(path) = timeline else {
        return segment;
    };
    let speaker = crate::speaker_timeline::wait_for_speaker(
        path,
        segment.channel,
        segment.start,
        segment.end,
        SPEAKER_TIMELINE_WAIT,
    )
    .await
    .unwrap_or(0);
    segment.speaker = speaker;
    segment.label = format!(
        "{} {}",
        if segment.channel == 0 {
            "Remote"
        } else {
            "In room"
        },
        speaker + 1
    );
    segment
}

async fn connect_socket(
    app_id: &str,
    access_token: &str,
    request_id: &str,
    language: &str,
    enable_speaker_info: bool,
) -> Result<DoubaoSocket, String> {
    let mut request = ENDPOINT
        .into_client_request()
        .map_err(|error| format!("invalid Doubao request: {error}"))?;
    for (name, value) in credential_headers(app_id, access_token, request_id)? {
        request.headers_mut().insert(
            HeaderName::from_bytes(name.as_bytes())
                .map_err(|_| format!("invalid Doubao header name: {name}"))?,
            HeaderValue::from_str(&value)
                .map_err(|_| format!("invalid Doubao header value: {name}"))?,
        );
    }
    let (mut socket, _) = connect_async(request)
        .await
        .map_err(|error| format!("Doubao connection failed: {error}"))?;
    socket
        .send(Message::Binary(
            encode_full_client_request(request_id, language, enable_speaker_info)?.into(),
        ))
        .await
        .map_err(|error| format!("Doubao initial request failed: {error}"))?;
    wait_for_initialization(&mut socket).await?;
    Ok(socket)
}

async fn receive_protocol_message(
    message: Option<Result<Message, tokio_tungstenite::tungstenite::Error>>,
) -> Result<Option<ServerMessage>, String> {
    match message {
        Some(Ok(Message::Binary(packet))) => decode_server_message(&packet).map(Some),
        Some(Ok(Message::Close(frame))) => Err(format!("Doubao closed the stream: {frame:?}")),
        Some(Ok(_)) => Ok(None),
        Some(Err(error)) => Err(format!("Doubao stream dropped: {error}")),
        None => Err("Doubao closed the stream unexpectedly.".into()),
    }
}

async fn wait_for_initialization(socket: &mut DoubaoSocket) -> Result<(), String> {
    loop {
        match receive_protocol_message(socket.next().await).await? {
            Some(ServerMessage::Error { code, message }) => {
                return Err(format!(
                    "{FATAL_ERROR_PREFIX}Doubao transcription failed ({code}): {message}"
                ));
            }
            Some(ServerMessage::Result { .. } | ServerMessage::Acknowledgement { .. }) => {
                return Ok(());
            }
            None => continue,
        }
    }
}

async fn next_channel_audio(
    pending: &mut PendingAudio,
    receiver: &mut mpsc::Receiver<AudioChunk>,
) -> Option<AudioChunk> {
    match pending.take() {
        Some(chunk) => Some(chunk),
        None => receiver.recv().await,
    }
}

pub async fn verify_credentials(app_id: &str, access_token: &str) -> Result<(), String> {
    let request_id = uuid::Uuid::new_v4().to_string();
    let mut socket = tokio::time::timeout(
        Duration::from_secs(8),
        connect_socket(app_id, access_token, &request_id, "zh-CN", false),
    )
    .await
    .map_err(|_| "Doubao credential verification timed out.".to_string())?
    .map_err(|error| error.trim_start_matches(FATAL_ERROR_PREFIX).to_string())?;
    let _ = socket.close(None).await;
    Ok(())
}

fn signal_ready() -> Result<(), String> {
    let Some(path) = std::env::var_os("ARCO_READY_FILE").map(PathBuf::from) else {
        return Ok(());
    };
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temporary = path.with_extension(format!("{}.tmp", std::process::id()));
    let mut file = File::create(&temporary).map_err(|error| error.to_string())?;
    file.write_all(b"doubao-ready\n")
        .and_then(|_| file.sync_all())
        .map_err(|error| error.to_string())?;
    fs::rename(&temporary, &path).map_err(|error| error.to_string())
}

async fn announce_channel_ready(
    ready: &mpsc::Sender<usize>,
    state: &mut ChannelState,
) -> Result<(), String> {
    if state.ready_announced {
        return Ok(());
    }
    state.ready_announced = true;
    ready
        .send(state.channel)
        .await
        .map_err(|_| format!("{FATAL_ERROR_PREFIX}Doubao readiness coordinator stopped."))
}

#[allow(clippy::too_many_arguments)]
async fn stream_connected_channel(
    socket: DoubaoSocket,
    receiver: &mut mpsc::Receiver<AudioChunk>,
    writer: &Arc<Mutex<TranscriptWriter>>,
    timeline: Option<&Path>,
    ready: &mpsc::Sender<usize>,
    role: &str,
    timeline_store: Option<&Arc<Mutex<crate::speaker_timeline::SpeakerTimelineStore>>>,
    state: &mut ChannelState,
) -> Result<bool, String> {
    let replay_buffered_seconds = buffered_audio_seconds(&state.pending, receiver);
    let (mut sink, mut stream) = socket.split();
    if state.connection_id > 1 {
        eprintln!(
            "ARCO_DOUBAO_RECONNECT channel={} connection={} buffered_audio={:.3}s pending_bytes={} max_replay_rate=1.25",
            state.channel,
            state.connection_id,
            replay_buffered_seconds,
            state.pending.bytes(),
        );
    }
    let mut sequence = 2i32;
    let mut lookahead: Option<AudioChunk> = None;
    let mut in_flight = InFlightAudio::default();
    let mut connection_origin: Option<f64> = None;
    let mut stream_started = false;
    let connection_started = Instant::now();
    let trace_protocol = std::env::var("ARCO_DOUBAO_TRACE").as_deref() == Ok("1");
    let mut pacer = None;
    let mut replay_reported = state.connection_id == 1 || replay_buffered_seconds == 0.0;
    let mut closing = false;
    let mut flush_sent = false;
    let dormant_deadline = Duration::from_secs(365 * 24 * 60 * 60);
    let final_response_deadline = tokio::time::sleep(dormant_deadline);
    let eof_deadline = tokio::time::sleep(dormant_deadline);
    let live_response_deadline = tokio::time::sleep(dormant_deadline);
    let heartbeat_deadline = tokio::time::sleep(dormant_deadline);
    let first_heartbeat = tokio::time::Instant::now() + state.heartbeat_interval;
    let mut heartbeat = tokio::time::interval_at(first_heartbeat, state.heartbeat_interval);
    heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut live_response_pending = false;
    let mut heartbeat_pending = false;
    tokio::pin!(
        final_response_deadline,
        eof_deadline,
        live_response_deadline,
        heartbeat_deadline
    );

    loop {
        state.observe_eof(receiver);
        if state.finalization_expired() {
            restore_connection_audio(&mut state.pending, &mut lookahead, &mut in_flight);
            return Err(state.finalization_error());
        }
        if let Some(deadline) = state.eof_deadline {
            eof_deadline.as_mut().reset(deadline);
        }

        tokio::select! {
            chunk = next_channel_audio(&mut state.pending, receiver), if !closing => {
                match chunk {
                    Some(chunk) => {
                        if chunk.has_speech_energy() && !live_response_pending {
                            live_response_pending = true;
                            live_response_deadline
                                .as_mut()
                                .reset(tokio::time::Instant::now() + state.live_response_timeout);
                        }
                        if !stream_started && chunk.is_digital_silence() {
                            writer
                                .lock()
                                .await
                                .advance(
                                    state.channel,
                                    chunk.end_frame() as f64 / SAMPLE_RATE as f64,
                                )
                                .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                            continue;
                        }
                        stream_started = true;
                        connection_origin
                            .get_or_insert(chunk.start_frame as f64 / SAMPLE_RATE as f64);
                        if let Err((error, previous, newer)) = queue_audio_chunk(
                            &mut sink,
                            &mut sequence,
                            &mut lookahead,
                            chunk,
                            &mut in_flight,
                            &mut pacer,
                            connection_started,
                            state.eof_deadline,
                        ).await {
                            state.pending.restore(newer);
                            state.pending.restore(previous);
                            in_flight.restore_into(&mut state.pending);
                            return Err(format!("Doubao audio send failed: {error}"));
                        }
                        if !replay_reported && state.pending.is_empty() && receiver.is_empty() {
                            eprintln!(
                                "ARCO_DOUBAO_REPLAY_CAUGHT_UP channel={} connection={} replayed_audio={:.3}s",
                                state.channel, state.connection_id, replay_buffered_seconds
                            );
                            replay_reported = true;
                        }
                    }
                    None => {
                        state.observe_eof(receiver);
                        if !stream_started {
                            writer
                                .lock()
                                .await
                                .complete_channel(state.channel)
                                .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                            let _ = sink.send(Message::Close(None)).await;
                            return Ok(true);
                        }
                        let final_audio = lookahead
                            .take()
                            .expect("a started stream must retain its last real audio chunk");
                        if let Err(error) = send_audio_chunk(
                            &mut sink,
                            &final_audio,
                            sequence,
                            &mut pacer,
                            connection_started,
                            state.eof_deadline,
                        ).await {
                            state.pending.restore(final_audio);
                            in_flight.restore_into(&mut state.pending);
                            return Err(format!("Doubao final audio send failed: {error}"));
                        }
                        // Mark the last real chunk as the logical EOF boundary
                        // for replay, even though it was an ordinary wire packet.
                        in_flight.record(sequence, final_audio, true);
                        sequence = sequence.saturating_add(1);
                        if let Err(error) = send_audio_flush(
                            &mut sink,
                            state.eof_deadline,
                        ).await {
                            in_flight.restore_into(&mut state.pending);
                            return Err(format!("Doubao final flush failed: {error}"));
                        }
                        flush_sent = true;
                        closing = true;
                        final_response_deadline
                            .as_mut()
                            .reset(tokio::time::Instant::now() + FINAL_ACK_TIMEOUT);
                    }
                }
            }
            message = stream.next() => {
                if matches!(&message, Some(Ok(_))) {
                    heartbeat_pending = false;
                }
                let message = match receive_protocol_message(message).await {
                    Ok(message) => message,
                    Err(error) => {
                        restore_connection_audio(
                            &mut state.pending,
                            &mut lookahead,
                            &mut in_flight,
                        );
                        return Err(if state.finalization_expired() {
                            state.finalization_error()
                        } else {
                            error
                        });
                    }
                };
                let Some(message) = message else { continue; };
                live_response_pending = false;
                if trace_protocol {
                    match &message {
                        ServerMessage::Result {
                            sequence,
                            is_final,
                            payload,
                        } => {
                            let utterances = payload
                                .get("result")
                                .and_then(|value| value.get("utterances"))
                                .or_else(|| payload.get("utterances"))
                                .and_then(Value::as_array);
                            let utterance_count = utterances.map_or(0, Vec::len);
                            let definite_count = utterances.map_or(0, |utterances| {
                                utterances
                                    .iter()
                                    .filter(|utterance| {
                                        utterance
                                            .get("definite")
                                            .and_then(Value::as_bool)
                                            .unwrap_or(false)
                                    })
                                    .count()
                            });
                            eprintln!(
                                "ARCO_DOUBAO_TRACE channel={} elapsed={:.3}s sequence={sequence:?} final={is_final} audio_duration_ms={:?} utterances={utterance_count} definite={definite_count}",
                                state.channel,
                                connection_started.elapsed().as_secs_f64(),
                                response_audio_duration_ms(payload),
                            );
                        }
                        ServerMessage::Acknowledgement { sequence } => eprintln!(
                            "ARCO_DOUBAO_TRACE channel={} elapsed={:.3}s ack_sequence={sequence}",
                            state.channel,
                            connection_started.elapsed().as_secs_f64(),
                        ),
                        ServerMessage::Error { code, .. } => eprintln!(
                            "ARCO_DOUBAO_TRACE channel={} elapsed={:.3}s error_code={code}",
                            state.channel,
                            connection_started.elapsed().as_secs_f64(),
                        ),
                    }
                }
                announce_channel_ready(ready, state).await?;
                let terminal_response = matches!(
                    &message,
                    ServerMessage::Result {
                        is_final: true,
                        ..
                    } if closing && flush_sent
                );
                let mut confirmation = apply_server_confirmation(
                    &message,
                    &mut in_flight,
                    terminal_response,
                );
                if closing && confirmation.confirmed_chunks > 0 && !in_flight.is_empty() {
                    final_response_deadline
                        .as_mut()
                        .reset(tokio::time::Instant::now() + FINAL_ACK_TIMEOUT);
                }
                match message {
                    ServerMessage::Error { code, message } => {
                        return Err(format!(
                            "{FATAL_ERROR_PREFIX}Doubao transcription failed ({code}): {message}"
                        ));
                    }
                    ServerMessage::Acknowledgement { .. } => {
                        writer
                            .lock()
                            .await
                            .advance_from_confirmation(state.channel, &confirmation)
                            .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                    }
                    ServerMessage::Result { payload, .. } => {
                        let origin = connection_origin.unwrap_or(0.0);
                        let segments = segments_from_connection_payload(
                            &payload,
                            state.channel,
                            false,
                            origin,
                        );
                        if role != "diarization" {
                            let definite = segments
                                .iter()
                                .map(segment_dedup_key)
                                .collect::<HashSet<_>>();
                            let tentative = segments_from_connection_payload(
                                &payload,
                                state.channel,
                                true,
                                origin,
                            )
                            .into_iter()
                            .filter(|segment| !definite.contains(&segment_dedup_key(segment)))
                            .collect::<Vec<_>>();
                            writer
                                .lock()
                                .await
                                .update_live(state.channel, &tentative)
                                .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                        }
                        let mut processed_until = confirmation
                            .confirmed_through_frame
                            .map(|frame| frame as f64 / SAMPLE_RATE as f64)
                            .unwrap_or(0.0);
                        let mut transcript_segments = Vec::new();
                        for segment in segments {
                            processed_until = processed_until.max(segment.end);
                            let key = segment_dedup_key(&segment);
                            if state.emitted.insert(key) {
                                let segment = if role == "asr" {
                                    segment
                                } else {
                                    state.speakers.relabel(segment, state.connection_id)
                                };
                                if let Some(store) = timeline_store {
                                    store.lock().await.update(
                                        state.channel,
                                        segment.end,
                                        vec![crate::speaker_timeline::SpeakerInterval {
                                            speaker: segment.speaker,
                                            start: segment.start,
                                            end: segment.end,
                                        }],
                                        Vec::new(),
                                    ).map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                                }
                                if role != "diarization" {
                                    let segment = if role == "asr" {
                                        if let Some(deadline) = state.eof_deadline {
                                            tokio::time::timeout_at(
                                                deadline,
                                                attribute_segment(segment, timeline),
                                            )
                                            .await
                                            .map_err(|_| state.finalization_error())?
                                        } else {
                                            attribute_segment(segment, timeline).await
                                        }
                                    } else {
                                        segment
                                    };
                                    transcript_segments.push(segment);
                                }
                            }
                        }

                        if state.finalization_expired() {
                            restore_connection_audio(
                                &mut state.pending,
                                &mut lookahead,
                                &mut in_flight,
                            );
                            return Err(state.finalization_error());
                        }
                        let mut transcript = writer.lock().await;
                        for segment in transcript_segments {
                            transcript
                                .append(&segment)
                                .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                        }
                        if !confirmation.final_confirmed && processed_until > 0.0 {
                            confirmation.absorb(
                                in_flight.confirm_through_frame(
                                    (processed_until * SAMPLE_RATE as f64).round() as usize,
                                ),
                            );
                        }
                        if closing && confirmation.final_confirmed {
                            transcript
                                .complete_channel(state.channel)
                                .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                            return Ok(true);
                        }
                        transcript
                            .advance(state.channel, processed_until)
                            .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;

                    }
                }
            }
            _ = heartbeat.tick(), if !closing && !heartbeat_pending => {
                if let Err(error) = await_audio_send(
                    sink.send(Message::Ping(Vec::new().into())),
                    state.eof_deadline,
                    LIVE_AUDIO_SEND_TIMEOUT,
                ).await {
                    restore_connection_audio(
                        &mut state.pending,
                        &mut lookahead,
                        &mut in_flight,
                    );
                    return Err(format!("Doubao heartbeat send failed: {error}"));
                }
                heartbeat_pending = true;
                heartbeat_deadline
                    .as_mut()
                    .reset(tokio::time::Instant::now() + state.heartbeat_timeout);
            }
            _ = &mut heartbeat_deadline, if heartbeat_pending && !closing => {
                restore_connection_audio(&mut state.pending, &mut lookahead, &mut in_flight);
                return Err("Doubao heartbeat timed out; reconnecting with unconfirmed audio.".into());
            }
            _ = &mut live_response_deadline, if live_response_pending && !closing => {
                restore_connection_audio(&mut state.pending, &mut lookahead, &mut in_flight);
                return Err("Doubao provider response timed out after incoming speech; reconnecting with unconfirmed audio.".into());
            }
            _ = &mut final_response_deadline, if closing && !in_flight.is_empty() => {
                restore_connection_audio(&mut state.pending, &mut lookahead, &mut in_flight);
                return Err(if state.finalization_expired() {
                    state.finalization_error()
                } else {
                    "Doubao final result timed out; reconnecting with unconfirmed audio.".into()
                });
            }
            _ = &mut eof_deadline, if state.eof_deadline.is_some() => {
                restore_connection_audio(&mut state.pending, &mut lookahead, &mut in_flight);
                return Err(state.finalization_error());
            }
        }
    }
}

struct ChannelState {
    pending: PendingAudio,
    emitted: HashSet<(i64, i64, String)>,
    speakers: SpeakerRegistry,
    ready_announced: bool,
    channel: usize,
    connection_id: u64,
    eof_deadline: Option<tokio::time::Instant>,
    live_response_timeout: Duration,
    heartbeat_interval: Duration,
    heartbeat_timeout: Duration,
}

impl ChannelState {
    fn new(channel: usize) -> Self {
        Self {
            pending: PendingAudio::default(),
            emitted: HashSet::new(),
            speakers: SpeakerRegistry::default(),
            ready_announced: false,
            channel,
            connection_id: 0,
            eof_deadline: None,
            live_response_timeout: LIVE_RESPONSE_TIMEOUT,
            heartbeat_interval: HEARTBEAT_INTERVAL,
            heartbeat_timeout: HEARTBEAT_TIMEOUT,
        }
    }

    fn observe_eof(&mut self, receiver: &mpsc::Receiver<AudioChunk>) {
        if receiver.is_closed()
            && receiver.is_empty()
            && self.pending.is_empty()
            && self.eof_deadline.is_none()
        {
            self.eof_deadline = Some(finalization_deadline(tokio::time::Instant::now()));
        }
    }

    fn finalization_expired(&self) -> bool {
        self.eof_deadline
            .is_some_and(|deadline| tokio::time::Instant::now() >= deadline)
    }

    fn finalization_error(&self) -> String {
        format!(
            "{FATAL_ERROR_PREFIX}Doubao could not finalize channel {} before the host shutdown deadline; buffered audio was not reported as saved.",
            self.channel
        )
    }
}

async fn send_audio_chunk<S>(
    sink: &mut S,
    chunk: &AudioChunk,
    sequence: i32,
    pacer: &mut Option<ReplayPacer>,
    connection_started: Instant,
    eof_deadline: Option<tokio::time::Instant>,
) -> Result<(), String>
where
    S: Sink<Message> + Unpin,
    S::Error: std::fmt::Display,
{
    let pacer = pacer.get_or_insert_with(|| ReplayPacer::new(chunk));
    let delay = pacer.delay_for(chunk, connection_started.elapsed());
    if !delay.is_zero() {
        if let Some(deadline) = eof_deadline {
            tokio::time::timeout_at(deadline, tokio::time::sleep(delay))
                .await
                .map_err(|_| {
                    format!(
                        "{FATAL_ERROR_PREFIX}Doubao audio replay exceeded the finalization deadline."
                    )
                })?;
        } else {
            tokio::time::sleep(delay).await;
        }
    }
    let packet = encode_audio_request(sequence, &chunk.data)?;
    await_audio_send(
        sink.send(Message::Binary(packet.into())),
        eof_deadline,
        LIVE_AUDIO_SEND_TIMEOUT,
    )
    .await
}

async fn await_audio_send<F, E>(
    send: F,
    eof_deadline: Option<tokio::time::Instant>,
    live_timeout: Duration,
) -> Result<(), String>
where
    F: std::future::Future<Output = Result<(), E>>,
    E: std::fmt::Display,
{
    let result = if let Some(deadline) = eof_deadline {
        tokio::time::timeout_at(deadline, send).await.map_err(|_| {
            format!("{FATAL_ERROR_PREFIX}Doubao audio send exceeded the finalization deadline.")
        })?
    } else {
        tokio::time::timeout(live_timeout, send)
            .await
            .map_err(|_| {
                "Doubao audio send timed out; reconnecting with unconfirmed audio.".to_string()
            })?
    };
    result.map_err(|error| error.to_string())
}

async fn send_audio_flush<S>(
    sink: &mut S,
    eof_deadline: Option<tokio::time::Instant>,
) -> Result<(), String>
where
    S: Sink<Message> + Unpin,
    S::Error: std::fmt::Display,
{
    await_audio_send(
        sink.send(Message::Binary(encode_audio_flush_request()?.into())),
        eof_deadline,
        LIVE_AUDIO_SEND_TIMEOUT,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn queue_audio_chunk<S>(
    sink: &mut S,
    sequence: &mut i32,
    lookahead: &mut Option<AudioChunk>,
    next: AudioChunk,
    in_flight: &mut InFlightAudio,
    pacer: &mut Option<ReplayPacer>,
    connection_started: Instant,
    eof_deadline: Option<tokio::time::Instant>,
) -> Result<(), (String, AudioChunk, AudioChunk)>
where
    S: Sink<Message> + Unpin,
    S::Error: std::fmt::Display,
{
    let Some(previous) = lookahead.replace(next) else {
        return Ok(());
    };
    if let Err(error) = send_audio_chunk(
        sink,
        &previous,
        *sequence,
        pacer,
        connection_started,
        eof_deadline,
    )
    .await
    {
        let newer = lookahead
            .take()
            .expect("queue_audio_chunk must retain the newer lookahead");
        return Err((error, previous, newer));
    }
    in_flight.record(*sequence, previous, false);
    *sequence = sequence.saturating_add(1);
    Ok(())
}

fn restore_connection_audio(
    pending: &mut PendingAudio,
    lookahead: &mut Option<AudioChunk>,
    in_flight: &mut InFlightAudio,
) {
    if let Some(chunk) = lookahead.take() {
        pending.restore(chunk);
    }
    in_flight.restore_into(pending);
}

#[allow(clippy::too_many_arguments)]
async fn connect_channel_socket(
    app_id: &str,
    access_token: &str,
    request_id: &str,
    language: &str,
    enable_speaker_info: bool,
    receiver: &mpsc::Receiver<AudioChunk>,
    state: &mut ChannelState,
) -> Result<DoubaoSocket, String> {
    let connect_deadline = tokio::time::Instant::now() + CONNECT_TIMEOUT;
    let connect = connect_socket(
        app_id,
        access_token,
        request_id,
        language,
        enable_speaker_info,
    );
    tokio::pin!(connect);
    loop {
        state.observe_eof(receiver);
        if state.finalization_expired() {
            return Err(state.finalization_error());
        }
        let deadline = state
            .eof_deadline
            .map(|eof| eof.min(connect_deadline))
            .unwrap_or(connect_deadline);
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return Err(if state.eof_deadline.is_some() {
                state.finalization_error()
            } else {
                "Doubao connection timed out.".into()
            });
        }
        let slice = deadline.duration_since(now).min(Duration::from_millis(50));
        match tokio::time::timeout(slice, connect.as_mut()).await {
            Ok(result) => return result,
            Err(_) => continue,
        }
    }
}

async fn wait_before_retry(
    delay: Duration,
    receiver: &mpsc::Receiver<AudioChunk>,
    state: &mut ChannelState,
) -> Result<(), String> {
    let live_deadline = tokio::time::Instant::now() + delay;
    loop {
        state.observe_eof(receiver);
        if state.finalization_expired() {
            return Err(state.finalization_error());
        }
        if let Some(deadline) = state.eof_deadline {
            let now = tokio::time::Instant::now();
            tokio::time::sleep(
                deadline
                    .saturating_duration_since(now)
                    .min(Duration::from_millis(50)),
            )
            .await;
            return Ok(());
        }
        let now = tokio::time::Instant::now();
        if now >= live_deadline {
            return Ok(());
        }
        tokio::time::sleep(
            live_deadline
                .duration_since(now)
                .min(Duration::from_millis(50)),
        )
        .await;
    }
}

async fn prime_channel_before_connect(
    receiver: &mut mpsc::Receiver<AudioChunk>,
    writer: &Arc<Mutex<TranscriptWriter>>,
    ready: &mpsc::Sender<usize>,
    state: &mut ChannelState,
) -> Result<bool, String> {
    if !state.pending.is_empty() {
        return Ok(true);
    }

    loop {
        match receiver.recv().await {
            Some(chunk) if chunk.is_digital_silence() => {
                writer
                    .lock()
                    .await
                    .advance(state.channel, chunk.end_frame() as f64 / SAMPLE_RATE as f64)
                    .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                announce_channel_ready(ready, state).await?;
            }
            Some(chunk) => {
                state.pending.restore(chunk);
                return Ok(true);
            }
            None => {
                writer
                    .lock()
                    .await
                    .complete_channel(state.channel)
                    .map_err(|error| format!("{FATAL_ERROR_PREFIX}{error}"))?;
                announce_channel_ready(ready, state).await?;
                return Ok(false);
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn run_channel(
    app_id: &str,
    access_token: &str,
    language: &str,
    channel: usize,
    enabled: bool,
    mut receiver: mpsc::Receiver<AudioChunk>,
    writer: Arc<Mutex<TranscriptWriter>>,
    timeline: Option<PathBuf>,
    ready: mpsc::Sender<usize>,
    role: &str,
    timeline_store: Option<Arc<Mutex<crate::speaker_timeline::SpeakerTimelineStore>>>,
) -> Result<(), String> {
    if !enabled {
        while receiver.recv().await.is_some() {}
        return Ok(());
    }
    let mut state = ChannelState::new(channel);
    let mut retry = 1u64;
    loop {
        if !prime_channel_before_connect(&mut receiver, &writer, &ready, &mut state)
            .await
            .map_err(|error| error.trim_start_matches(FATAL_ERROR_PREFIX).to_string())?
        {
            return Ok(());
        }
        state.observe_eof(&receiver);
        if state.finalization_expired() {
            return Err(state
                .finalization_error()
                .trim_start_matches(FATAL_ERROR_PREFIX)
                .to_string());
        }
        state.connection_id += 1;
        let request_id = uuid::Uuid::new_v4().to_string();
        let attempt = match connect_channel_socket(
            app_id,
            access_token,
            &request_id,
            language,
            role != "asr",
            &receiver,
            &mut state,
        )
        .await
        {
            Ok(socket) => {
                announce_channel_ready(&ready, &mut state).await?;
                stream_connected_channel(
                    socket,
                    &mut receiver,
                    &writer,
                    timeline.as_deref(),
                    &ready,
                    role,
                    timeline_store.as_ref(),
                    &mut state,
                )
                .await
            }
            Err(error) => Err(error),
        };
        match attempt {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error) if is_fatal_channel_error(&error) => {
                return Err(error.trim_start_matches(FATAL_ERROR_PREFIX).to_string());
            }
            Err(error) => eprintln!(
                "[doubao channel {channel}] {error}; retrying in {retry}s; buffered_audio={:.3}s pending_bytes={}",
                buffered_audio_seconds(&state.pending, &receiver),
                state.pending.bytes(),
            ),
        }
        wait_before_retry(Duration::from_secs(retry), &receiver, &mut state)
            .await
            .map_err(|error| error.trim_start_matches(FATAL_ERROR_PREFIX).to_string())?;
        retry = next_retry_delay(retry);
    }
}

async fn send_stereo_chunk(
    senders: &[mpsc::Sender<AudioChunk>; 2],
    stereo: &[u8],
    start_frame: usize,
) -> Result<(), String> {
    let (remote, room) = split_stereo_pcm(stereo)?;
    let remote_send = senders[0].send(AudioChunk {
        data: remote,
        start_frame,
    });
    let room_send = senders[1].send(AudioChunk {
        data: room,
        start_frame,
    });
    let (remote_result, room_result) = tokio::join!(remote_send, room_send);
    remote_result
        .and(room_result)
        .map_err(|_| "Doubao audio worker stopped.".to_string())
}

async fn pump_stdin(senders: [mpsc::Sender<AudioChunk>; 2]) -> Result<(), String> {
    let mut input = tokio::io::stdin();
    let mut carry = Vec::new();
    let mut next_frame = 0usize;
    loop {
        let mut buffer = vec![0u8; READ_CHUNK_BYTES];
        let read = input
            .read(&mut buffer)
            .await
            .map_err(|error| format!("could not read native audio: {error}"))?;
        if read == 0 {
            break;
        }
        carry.extend_from_slice(&buffer[..read]);
        while carry.len() >= READ_CHUNK_BYTES {
            let tail = carry.split_off(READ_CHUNK_BYTES);
            let chunk = std::mem::replace(&mut carry, tail);
            send_stereo_chunk(&senders, &chunk, next_frame).await?;
            next_frame += chunk.len() / STEREO_FRAME_BYTES;
        }
    }
    let aligned = carry.len() / STEREO_FRAME_BYTES * STEREO_FRAME_BYTES;
    if aligned > 0 {
        send_stereo_chunk(&senders, &carry[..aligned], next_frame).await?;
    }
    Ok(())
}

fn active_channels_for_mode(mode: &str) -> [bool; 2] {
    match mode {
        "system" => [true, false],
        "mic" => [false, true],
        _ => [true, true],
    }
}

pub async fn run_transcriber(transcript_path: &Path) -> Result<(), String> {
    let app_id = std::env::var("DOUBAO_SPEECH_API_KEY")
        .or_else(|_| std::env::var("DOUBAO_APP_ID"))
        .unwrap_or_default();
    let access_token = std::env::var("DOUBAO_ACCESS_TOKEN").unwrap_or_default();
    credential_headers(&app_id, &access_token, "startup")?;
    let language = std::env::var("DOUBAO_LANG").unwrap_or_else(|_| "zh-CN".into());
    let active = active_channels_for_mode(
        &std::env::var("ARCO_AUDIO_MODE").unwrap_or_else(|_| "both".into()),
    );
    let expected_ready = active.iter().filter(|&&value| value).count();
    let session_started_at = std::env::var("ARCO_SESSION_STARTED_AT_UNIX")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| chrono::Utc::now().timestamp_millis() as f64 / 1_000.0);
    let mut transcript_writer =
        TranscriptWriter::new(transcript_path.to_path_buf(), session_started_at)?;
    transcript_writer.set_active_channels(active);
    let writer = Arc::new(Mutex::new(transcript_writer));
    let timeline = std::env::var_os("ARCO_SPEAKER_TIMELINE_FILE").map(PathBuf::from);
    let role = std::env::var("ARCO_TRANSCRIBER_ROLE").unwrap_or_else(|_| "combined".into());
    if !matches!(role.as_str(), "combined" | "asr" | "diarization") {
        return Err(format!("unsupported Doubao transcriber role: {role}"));
    }
    let timeline_store = if role == "diarization" {
        Some(Arc::new(Mutex::new(
            crate::speaker_timeline::SpeakerTimelineStore::new(timeline.clone().ok_or_else(
                || "Doubao diarization requires a shared speaker timeline.".to_string(),
            )?),
        )))
    } else {
        None
    };
    let buffer_seconds = std::env::var("ARCO_AUDIO_BUFFER_SECONDS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok());
    let capacity = audio_buffer_capacity(buffer_seconds);
    let (remote_sender, remote_receiver) = mpsc::channel(capacity);
    let (room_sender, room_receiver) = mpsc::channel(capacity);
    let (ready_sender, mut ready_receiver) = mpsc::channel(2);
    let pump = pump_stdin([remote_sender, room_sender]);
    let remote = run_channel(
        app_id.trim(),
        access_token.trim(),
        &language,
        0,
        active[0],
        remote_receiver,
        writer.clone(),
        timeline.clone(),
        ready_sender.clone(),
        &role,
        timeline_store.clone(),
    );
    let room = run_channel(
        app_id.trim(),
        access_token.trim(),
        &language,
        1,
        active[1],
        room_receiver,
        writer.clone(),
        timeline,
        ready_sender,
        &role,
        timeline_store,
    );
    let readiness = async move {
        let mut channels = HashSet::new();
        while channels.len() < expected_ready {
            let channel = ready_receiver
                .recv()
                .await
                .ok_or_else(|| "Doubao stopped before becoming ready.".to_string())?;
            channels.insert(channel);
        }
        signal_ready()
    };
    let run_result = tokio::try_join!(pump, remote, room, readiness);
    let mut writer = writer.lock().await;
    let flush_result = writer.flush_all();
    let clear_live_result = writer.clear_live();
    drop(writer);
    match run_result {
        Ok(_) => flush_result.and(clear_live_result),
        Err(error) => {
            if let Err(flush_error) = flush_result {
                eprintln!("[doubao transcript] final ordered flush failed: {flush_error}");
            }
            if let Err(clear_error) = clear_live_result {
                eprintln!("[doubao transcript] live snapshot cleanup failed: {clear_error}");
            }
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use tokio::net::{TcpListener, TcpStream};
    use tokio_tungstenite::{accept_async, WebSocketStream};

    #[derive(Default)]
    struct ResettingSink;

    impl Sink<Message> for ResettingSink {
        type Error = &'static str;

        fn poll_ready(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn start_send(self: Pin<&mut Self>, _item: Message) -> Result<(), Self::Error> {
            Err("connection reset")
        }

        fn poll_flush(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn poll_close(
            self: Pin<&mut Self>,
            _context: &mut Context<'_>,
        ) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }

    async fn local_websocket_pair() -> (DoubaoSocket, WebSocketStream<TcpStream>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            accept_async(stream).await.unwrap()
        });
        let (client, _) = connect_async(format!("ws://{address}")).await.unwrap();
        (client, server.await.unwrap())
    }

    #[tokio::test]
    async fn initialization_waits_for_the_server_result_before_audio_can_start() {
        let (mut socket, mut server) = local_websocket_pair().await;
        let initialization = wait_for_initialization(&mut socket);
        tokio::pin!(initialization);

        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut initialization)
                .await
                .is_err(),
            "initialization must not complete before the provider acknowledges the request"
        );

        server
            .send(result_message(1, false, json!({ "result": {} })))
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(1), &mut initialization)
            .await
            .expect("provider acknowledgement should complete initialization")
            .unwrap();
    }

    fn result_message(sequence: i32, is_final: bool, payload: Value) -> Message {
        let flags = 0x01 | if is_final { 0x02 } else { 0x00 };
        let payload = serde_json::to_vec(&payload).unwrap();
        let mut packet = vec![0x11, 0x90 | flags, 0x10, 0x00];
        packet.extend_from_slice(&sequence.to_be_bytes());
        packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        packet.extend_from_slice(&payload);
        Message::Binary(packet.into())
    }

    fn tenth_second_chunk(start_frame: usize, byte: u8) -> AudioChunk {
        AudioChunk {
            data: vec![byte; SAMPLE_RATE * MONO_FRAME_BYTES / 10],
            start_frame,
        }
    }

    #[test]
    fn credential_headers_use_the_official_doubao_streaming_contract() {
        let headers = credential_headers("app-id", "access-token", "request-id").unwrap();
        assert_eq!(headers.get("X-Api-App-Key").unwrap(), "app-id");
        assert_eq!(headers.get("X-Api-Access-Key").unwrap(), "access-token");
        assert_eq!(
            headers.get("X-Api-Resource-Id").unwrap(),
            "volc.seedasr.sauc.duration",
            "the optimized two-pass endpoint must use the ASR 2.0 resource"
        );
        assert_eq!(headers.get("X-Api-Request-Id").unwrap(), "request-id");
    }

    #[test]
    fn realtime_transcription_uses_the_official_optimized_duplex_endpoint() {
        assert_eq!(
            ENDPOINT,
            "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
        );
    }

    #[test]
    fn credential_headers_support_the_new_console_single_api_key() {
        let headers = credential_headers("api-key-123456789", "", "request-id").unwrap();
        assert_eq!(headers.get("X-Api-Key").unwrap(), "api-key-123456789");
        assert!(!headers.contains_key("X-Api-App-Key"));
        assert!(!headers.contains_key("X-Api-Access-Key"));
        assert_eq!(headers.get("X-Api-Resource-Id").unwrap(), RESOURCE_ID);
        assert_eq!(headers.get("X-Api-Request-Id").unwrap(), "request-id");
    }

    #[test]
    fn first_request_is_gzip_json_with_the_official_initial_sequence() {
        let packet = encode_full_client_request("request-id", "zh-CN", true).unwrap();
        assert_eq!(&packet[..4], &[0x11, 0x11, 0x11, 0x00]);
        assert_eq!(i32::from_be_bytes(packet[4..8].try_into().unwrap()), 1);
        let payload_size = u32::from_be_bytes(packet[8..12].try_into().unwrap()) as usize;
        assert_eq!(packet.len(), 12 + payload_size);
    }

    #[test]
    fn first_request_uses_the_meeting_stream_contract() {
        let packet = encode_full_client_request("request-id", "zh-CN", true).unwrap();

        assert_eq!(
            &packet[..4],
            &[0x11, 0x11, 0x11, 0x00],
            "the full client request must carry the official positive sequence flag"
        );
        assert_eq!(i32::from_be_bytes(packet[4..8].try_into().unwrap()), 1);
        let payload_size = u32::from_be_bytes(packet[8..12].try_into().unwrap()) as usize;
        assert_eq!(packet.len(), 12 + payload_size);
        let request: Value =
            serde_json::from_slice(&gunzip(&packet[12..12 + payload_size]).unwrap()).unwrap();

        assert!(
            request["audio"].get("language").is_none(),
            "language is only supported by bigmodel_nostream and must not be sent to bigmodel_async"
        );
        assert!(
            request["request"].get("language").is_none(),
            "language is only supported by bigmodel_nostream and must not be sent to bigmodel_async"
        );
        assert_eq!(
            request["request"]["enable_nonstream"], true,
            "the optimized endpoint must enable the second-pass recognizer"
        );
        assert_eq!(
            request["request"]["end_window_size"], 800,
            "a natural sentence pause should commit promptly instead of waiting for a 20-second provider split"
        );
        assert_eq!(request["request"]["force_to_speech_time"], 1_000);
        assert_eq!(
            request["request"]["result_type"], "full",
            "the validated optimized two-pass contract returns a cumulative result"
        );
    }

    #[test]
    fn ordinary_audio_requests_carry_monotonic_positive_sequences() {
        let streaming = encode_audio_request(2, &[1, 2, 3, 4]).unwrap();
        assert_eq!(&streaming[..4], &[0x11, 0x21, 0x01, 0x00]);
        assert_eq!(i32::from_be_bytes(streaming[4..8].try_into().unwrap()), 2);

        let streaming_payload_size =
            u32::from_be_bytes(streaming[8..12].try_into().unwrap()) as usize;
        assert_eq!(streaming.len(), 12 + streaming_payload_size);
        assert_eq!(gunzip(&streaming[12..]).unwrap(), [1, 2, 3, 4]);
    }

    #[tokio::test]
    async fn eof_sends_the_last_real_audio_normally_then_an_empty_last_no_seq_flush() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(2);
        let first = tenth_second_chunk(0, 3);
        let last = tenth_second_chunk(SAMPLE_RATE / 10, 4);
        sender.send(first.clone()).await.unwrap();
        sender.send(last.clone()).await.unwrap();
        drop(sender);
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        let stream = tokio::spawn(async move {
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            )
            .await
        });

        let first_packet = match server.next().await {
            Some(Ok(Message::Binary(packet))) => packet,
            other => panic!("expected first ordinary audio packet, got {other:?}"),
        };
        assert_eq!(&first_packet[..4], &[0x11, 0x21, 0x01, 0x00]);
        assert_eq!(
            i32::from_be_bytes(first_packet[4..8].try_into().unwrap()),
            2
        );
        let first_size = u32::from_be_bytes(first_packet[8..12].try_into().unwrap()) as usize;
        assert_eq!(
            gunzip(&first_packet[12..12 + first_size]).unwrap(),
            first.data
        );

        let last_packet = match server.next().await {
            Some(Ok(Message::Binary(packet))) => packet,
            other => panic!("expected last real audio as an ordinary packet, got {other:?}"),
        };
        assert_eq!(
            &last_packet[..4],
            &[0x11, 0x21, 0x01, 0x00],
            "real audio must never be overloaded as the protocol LAST marker"
        );
        assert_eq!(i32::from_be_bytes(last_packet[4..8].try_into().unwrap()), 3);
        let last_size = u32::from_be_bytes(last_packet[8..12].try_into().unwrap()) as usize;
        assert_eq!(gunzip(&last_packet[12..12 + last_size]).unwrap(), last.data);

        let flush_packet = tokio::time::timeout(Duration::from_secs(1), server.next())
            .await
            .expect("EOF must send a separate empty LAST packet")
            .expect("client closed before sending the LAST packet")
            .expect("fake websocket failed");
        let Message::Binary(flush_packet) = flush_packet else {
            panic!("expected binary LAST packet, got {flush_packet:?}");
        };
        assert_eq!(
            &flush_packet[..4],
            &[0x11, 0x22, 0x01, 0x00],
            "Mizzen's validated two-pass flush is LAST_NO_SEQ with gzip"
        );
        let flush_size = u32::from_be_bytes(flush_packet[4..8].try_into().unwrap()) as usize;
        assert_eq!(flush_packet.len(), 8 + flush_size);
        assert!(gunzip(&flush_packet[8..]).unwrap().is_empty());

        stream.abort();
    }

    #[test]
    fn audio_is_packetized_at_the_official_two_hundred_millisecond_cadence() {
        assert_eq!(READ_CHUNK_BYTES, SAMPLE_RATE * STEREO_FRAME_BYTES / 5);
        assert_eq!(audio_buffer_capacity(Some(1)), 5);
    }

    #[test]
    fn stereo_pcm_is_split_into_lossless_remote_and_microphone_channels() {
        let (remote, microphone) =
            split_stereo_pcm(&[0x01, 0x02, 0x11, 0x12, 0x03, 0x04, 0x13, 0x14]).unwrap();
        assert_eq!(remote, [0x01, 0x02, 0x03, 0x04]);
        assert_eq!(microphone, [0x11, 0x12, 0x13, 0x14]);
        assert!(split_stereo_pcm(&[0, 1, 2]).is_err());
    }

    #[test]
    fn leading_silence_detection_is_conservative_and_never_drops_quiet_audio() {
        assert!(AudioChunk {
            data: vec![0; 32],
            start_frame: 0,
        }
        .is_digital_silence());
        assert!(!AudioChunk {
            data: vec![0, 0, 0, 1],
            start_frame: 0,
        }
        .is_digital_silence());
        assert!(!AudioChunk {
            data: Vec::new(),
            start_frame: 0,
        }
        .is_digital_silence());
    }

    #[test]
    fn speech_watchdog_ignores_room_noise_but_arms_for_voice_energy() {
        let pcm = |sample: i16| AudioChunk {
            data: sample
                .to_le_bytes()
                .into_iter()
                .cycle()
                .take(SAMPLE_RATE * MONO_FRAME_BYTES / 10)
                .collect(),
            start_frame: 0,
        };

        assert!(!pcm(0).has_speech_energy());
        assert!(!pcm(200).has_speech_energy());
        assert!(pcm(800).has_speech_energy());
    }

    #[test]
    fn server_error_packet_surfaces_code_and_message() {
        let message = b"invalid access token";
        let mut packet = vec![0x11, 0xf0, 0x00, 0x00];
        packet.extend_from_slice(&401u32.to_be_bytes());
        packet.extend_from_slice(&(message.len() as u32).to_be_bytes());
        packet.extend_from_slice(message);
        assert_eq!(
            decode_server_message(&packet).unwrap(),
            ServerMessage::Error {
                code: 401,
                message: "invalid access token".into(),
            }
        );
    }

    #[test]
    fn malformed_server_packet_is_rejected_instead_of_panicking() {
        assert!(decode_server_message(&[0x11, 0x90]).is_err());
    }

    #[test]
    fn only_definite_utterances_are_emitted_before_the_final_package() {
        let payload = json!({ "result": { "utterances": [
            { "text": "stable", "start_time": 0.0, "end_time": 1000.0, "definite": true },
            { "text": "draft", "start_time": 1000.0, "end_time": 2000.0, "definite": false }
        ]}});
        assert_eq!(segments_from_payload(&payload, 0, false).len(), 1);
        assert_eq!(segments_from_payload(&payload, 0, true).len(), 2);
    }

    #[test]
    fn definite_text_is_not_dropped_when_the_provider_omits_or_stringifies_timestamps() {
        let payload = json!({ "result": { "utterances": [
            { "text": "first sentence", "definite": true },
            {
                "text": "second sentence",
                "start_time": "1000",
                "end_time": "2000",
                "definite": true
            }
        ]}});

        let segments = segments_from_payload(&payload, 1, false);

        assert_eq!(
            segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<Vec<_>>(),
            ["first sentence", "second sentence"]
        );
        assert_eq!((segments[0].start, segments[0].end), (0.0, 0.0));
        assert_eq!((segments[1].start, segments[1].end), (1.0, 2.0));
    }

    #[test]
    fn provider_speaker_ids_are_preserved_as_arco_source_labels() {
        let payload = json!({ "result": { "utterances": [
            { "text": "first", "start_time": 0.0, "end_time": 500.0, "definite": true, "additions": { "speaker": "1" } },
            { "text": "second", "start_time": 500.0, "end_time": 1000.0, "definite": true, "additions": { "speaker": "2" } }
        ]}});
        let segments = segments_from_payload(&payload, 0, false);
        assert_eq!(segments[0].label, "Remote 1");
        assert_eq!(segments[1].label, "Remote 2");
        assert_eq!((segments[0].speaker, segments[1].speaker), (0, 1));
    }

    #[test]
    fn optimized_endpoint_zero_based_speaker_ids_are_preserved() {
        // Captured from the real bigmodel_async response with SSD 200 enabled.
        let payload = json!({ "result": { "utterances": [
            { "text": "first", "start_time": 0, "end_time": 500, "definite": true, "additions": { "speaker_id": "0" } },
            { "text": "second", "start_time": 500, "end_time": 1000, "definite": true, "additions": { "speaker_id": "1" } }
        ]}});

        let segments = segments_from_payload(&payload, 1, false);

        assert_eq!(segments.len(), 2);
        assert_eq!((segments[0].speaker, segments[1].speaker), (0, 1));
        assert_eq!(
            (segments[0].label.as_str(), segments[1].label.as_str()),
            ("In room 1", "In room 2")
        );
    }

    #[test]
    fn full_request_explicitly_enables_doubao_speaker_separation() {
        let packet = encode_full_client_request("request-id", "zh-CN", true).unwrap();
        let size = u32::from_be_bytes(packet[8..12].try_into().unwrap()) as usize;
        let payload = gunzip(&packet[12..12 + size]).unwrap();
        let request: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(request["request"]["enable_speaker_info"], true);
        assert_eq!(
            request["request"]["ssd_version"], "200",
            "Volcengine requires SSD 200 when speaker separation is enabled"
        );
        assert_eq!(request["request"]["show_utterances"], true);
    }

    #[test]
    fn full_request_omits_ssd_when_speaker_separation_is_disabled() {
        let packet = encode_full_client_request("request-id", "zh-CN", false).unwrap();
        let size = u32::from_be_bytes(packet[8..12].try_into().unwrap()) as usize;
        let payload = gunzip(&packet[12..12 + size]).unwrap();
        let request: Value = serde_json::from_slice(&payload).unwrap();

        assert_eq!(request["request"]["enable_speaker_info"], false);
        assert!(request["request"].get("ssd_version").is_none());
    }

    #[tokio::test]
    async fn failed_audio_chunk_is_retried_byte_for_byte_before_new_channel_audio() {
        let failed = AudioChunk {
            data: vec![7, 8, 9, 10],
            start_frame: 4_200,
        };
        let newer = AudioChunk {
            data: vec![11, 12, 13, 14],
            start_frame: 4_202,
        };
        let newest = AudioChunk {
            data: vec![15, 16, 17, 18],
            start_frame: 4_204,
        };
        let (sender, mut receiver) = mpsc::channel(2);
        sender.send(newest.clone()).await.unwrap();
        drop(sender);
        let mut sink = ResettingSink;
        let mut sequence = 2;
        let mut lookahead = Some(failed.clone());
        let mut in_flight = InFlightAudio::default();
        let mut pacer = None;
        let (error, failed_again, newer_again) = queue_audio_chunk(
            &mut sink,
            &mut sequence,
            &mut lookahead,
            newer.clone(),
            &mut in_flight,
            &mut pacer,
            Instant::now(),
            None,
        )
        .await
        .expect_err("the fake socket must reset while sending the held chunk");
        assert_eq!(error, "connection reset");
        assert_eq!(sequence, 2, "failed sends must not consume a sequence");

        let mut pending = PendingAudio::default();
        pending.restore(newer_again);
        pending.restore(failed_again);

        assert_eq!(pending.take(), Some(failed));
        assert_eq!(pending.take(), Some(newer));
        assert_eq!(pending.take(), None);
        assert_eq!(receiver.recv().await, Some(newest));
        assert_eq!(receiver.recv().await, None);
    }

    #[test]
    fn reconnect_replay_is_capped_at_one_point_two_five_times_realtime() {
        let first = AudioChunk {
            data: vec![1; READ_CHUNK_BYTES / 2],
            start_frame: SAMPLE_RATE,
        };
        let pacer = ReplayPacer::new(&first);
        assert_eq!(pacer.delay_for(&first, Duration::ZERO), Duration::ZERO);

        let second = AudioChunk {
            data: vec![2; READ_CHUNK_BYTES / 2],
            start_frame: first.end_frame(),
        };
        assert_eq!(
            pacer.delay_for(&second, Duration::ZERO),
            Duration::from_millis(160)
        );
        assert_eq!(
            pacer.delay_for(&second, Duration::from_millis(200)),
            Duration::ZERO
        );

        let ten_seconds = AudioChunk {
            data: vec![3; READ_CHUNK_BYTES / 2],
            start_frame: first.end_frame() + SAMPLE_RATE * 10 - READ_CHUNK_BYTES / 4,
        };
        assert_eq!(
            pacer.delay_for(&ten_seconds, Duration::ZERO),
            Duration::from_secs(8)
        );
    }

    #[test]
    fn reset_after_final_send_replays_the_final_audio_on_the_next_connection() {
        let final_audio = AudioChunk {
            data: vec![21, 22, 23, 24],
            start_frame: 9_900,
        };
        let mut pending = PendingAudio::default();
        let mut lookahead = None;
        let mut in_flight = InFlightAudio::default();
        in_flight.record(2, final_audio.clone(), true);

        restore_connection_audio(&mut pending, &mut lookahead, &mut in_flight);

        assert_eq!(pending.take(), Some(final_audio));
        assert_eq!(pending.take(), None);
        assert!(in_flight.is_empty());
    }

    #[test]
    fn reset_replays_every_unacknowledged_sent_chunk_in_original_order() {
        let first = AudioChunk {
            data: vec![1, 2],
            start_frame: 100,
        };
        let second = AudioChunk {
            data: vec![3, 4],
            start_frame: 101,
        };
        let held = AudioChunk {
            data: vec![5, 6],
            start_frame: 102,
        };
        let queued = AudioChunk {
            data: vec![7, 8],
            start_frame: 103,
        };
        let mut in_flight = InFlightAudio::default();
        in_flight.record(2, first.clone(), false);
        in_flight.record(3, second.clone(), false);
        let mut pending = PendingAudio::default();
        pending.restore(queued.clone());
        let mut lookahead = Some(held.clone());

        restore_connection_audio(&mut pending, &mut lookahead, &mut in_flight);

        assert_eq!(pending.take(), Some(first));
        assert_eq!(pending.take(), Some(second));
        assert_eq!(pending.take(), Some(held));
        assert_eq!(pending.take(), Some(queued));
        assert_eq!(pending.take(), None);
    }

    #[test]
    fn acknowledgements_advance_a_monotonic_watermark_and_only_replay_the_tail() {
        let chunks: Vec<_> = (0..3)
            .map(|index| AudioChunk {
                data: vec![index as u8; 2],
                start_frame: 200 + index,
            })
            .collect();
        let mut in_flight = InFlightAudio::default();
        for (index, chunk) in chunks.iter().cloned().enumerate() {
            in_flight.record(index as i32 + 2, chunk, false);
        }

        let confirmation = in_flight.confirm_through(3);
        assert_eq!(confirmation.confirmed_chunks, 2);
        assert!(!confirmation.final_confirmed);
        assert_eq!(in_flight.len(), 1);

        let mut pending = PendingAudio::default();
        in_flight.restore_into(&mut pending);
        assert_eq!(pending.take(), Some(chunks[2].clone()));
        assert_eq!(pending.take(), None);
    }

    #[test]
    fn replay_tracking_never_discards_unconfirmed_audio() {
        let mut in_flight = InFlightAudio::default();
        for sequence in 2..102 {
            in_flight.record(
                sequence,
                AudioChunk {
                    data: vec![sequence as u8; READ_CHUNK_BYTES / 2],
                    start_frame: (sequence as usize - 2) * SAMPLE_RATE / AUDIO_CHUNKS_PER_SECOND,
                },
                false,
            );
        }

        assert_eq!(in_flight.len(), 100);
        assert_eq!(in_flight.chunks.front().unwrap().sequence, 2);
        assert_eq!(in_flight.chunks.back().unwrap().sequence, 101);
    }

    #[test]
    fn final_completion_requires_a_terminal_result_after_client_flush_not_a_transport_ack() {
        let final_audio = AudioChunk {
            data: vec![9, 10],
            start_frame: 300,
        };
        let mut acked = InFlightAudio::default();
        acked.record(2, final_audio.clone(), true);
        assert!(
            !apply_server_confirmation(
                &ServerMessage::Acknowledgement { sequence: -2 },
                &mut acked,
                false,
            )
            .final_confirmed,
            "SERVER_ACK confirms receipt, not persisted final transcript"
        );

        let mut result = InFlightAudio::default();
        result.record(2, final_audio, true);
        assert!(
            apply_server_confirmation(
                &ServerMessage::Result {
                    sequence: Some(-2),
                    is_final: true,
                    payload: Value::Null,
                },
                &mut result,
                true,
            )
            .final_confirmed
        );

        let mut ordinary = InFlightAudio::default();
        ordinary.record(
            2,
            AudioChunk {
                data: vec![11, 12],
                start_frame: 301,
            },
            false,
        );
        assert!(
            !apply_server_confirmation(
                &ServerMessage::Acknowledgement { sequence: 2 },
                &mut ordinary,
                false,
            )
            .final_confirmed
        );
    }

    #[test]
    fn sentence_finals_cannot_confirm_eof_until_the_client_has_sent_its_flush() {
        let mut in_flight = InFlightAudio::default();
        for sequence in 2..10 {
            in_flight.record(
                sequence,
                AudioChunk {
                    data: vec![sequence as u8; MONO_FRAME_BYTES],
                    start_frame: sequence as usize,
                },
                false,
            );
        }
        in_flight.record(
            10,
            AudioChunk {
                data: vec![10; MONO_FRAME_BYTES],
                start_frame: 10,
            },
            true,
        );

        let stale = apply_server_confirmation(
            &ServerMessage::Result {
                sequence: Some(-5),
                is_final: true,
                payload: Value::Null,
            },
            &mut in_flight,
            false,
        );
        assert!(!stale.final_confirmed);
        assert!(in_flight.contains_final_packet());

        let unsequenced = apply_server_confirmation(
            &ServerMessage::Result {
                sequence: None,
                is_final: true,
                payload: Value::Null,
            },
            &mut in_flight,
            false,
        );
        assert!(!unsequenced.final_confirmed);
        assert!(in_flight.contains_final_packet());

        let covering = apply_server_confirmation(
            &ServerMessage::Result {
                sequence: Some(-10),
                is_final: true,
                payload: Value::Null,
            },
            &mut in_flight,
            true,
        );
        assert!(covering.final_confirmed);
        assert!(in_flight.is_empty());
    }

    #[test]
    fn unexpected_final_result_before_client_eof_preserves_unconfirmed_audio_for_replay() {
        let chunks: Vec<_> = (0..2)
            .map(|index| AudioChunk {
                data: vec![index as u8; MONO_FRAME_BYTES],
                start_frame: 500 + index,
            })
            .collect();
        let mut in_flight = InFlightAudio::default();
        for (index, chunk) in chunks.iter().cloned().enumerate() {
            in_flight.record(index as i32 + 2, chunk, false);
        }

        let confirmation = apply_server_confirmation(
            &ServerMessage::Result {
                sequence: Some(-3),
                is_final: true,
                payload: Value::Null,
            },
            &mut in_flight,
            false,
        );

        assert!(!confirmation.final_confirmed);
        let mut pending = PendingAudio::default();
        in_flight.restore_into(&mut pending);
        assert_eq!(pending.take(), Some(chunks[0].clone()));
        assert_eq!(pending.take(), Some(chunks[1].clone()));
    }

    #[test]
    fn eof_finalization_deadline_allows_the_full_provider_final_ack_window() {
        let started = tokio::time::Instant::now();
        let deadline = finalization_deadline(started);
        assert_eq!(deadline.duration_since(started), EOF_FINALIZATION_TIMEOUT);
        assert_eq!(EOF_FINALIZATION_TIMEOUT, FINAL_ACK_TIMEOUT);
    }

    #[tokio::test]
    async fn leading_digital_silence_is_consumed_before_opening_the_optimized_socket() {
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(3);
        let first_speech = tenth_second_chunk(SAMPLE_RATE / 5, 7);
        sender.send(tenth_second_chunk(0, 0)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 0))
            .await
            .unwrap();
        sender.send(first_speech.clone()).await.unwrap();
        let (ready, mut ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);

        assert!(
            prime_channel_before_connect(&mut receiver, &writer, &ready, &mut state)
                .await
                .unwrap()
        );
        assert_eq!(ready_receiver.recv().await, Some(0));
        assert_eq!(state.pending.take(), Some(first_speech));
        assert_eq!(writer.lock().await.processed_until[0], 0.2);
    }

    #[tokio::test]
    async fn all_silent_channel_finishes_locally_without_opening_a_provider_socket() {
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(2);
        sender.send(tenth_second_chunk(0, 0)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 0))
            .await
            .unwrap();
        drop(sender);
        let (ready, mut ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);

        assert!(
            !prime_channel_before_connect(&mut receiver, &writer, &ready, &mut state)
                .await
                .unwrap()
        );
        assert_eq!(ready_receiver.recv().await, Some(0));
        assert!(state.pending.is_empty());
        assert!(writer.lock().await.processed_until[0].is_infinite());
    }

    #[tokio::test]
    async fn closed_receiver_does_not_start_finalization_while_audio_is_still_buffered() {
        let (sender, receiver) = mpsc::channel(2);
        sender.send(tenth_second_chunk(0, 7)).await.unwrap();
        drop(sender);

        let mut state = ChannelState::new(0);
        state.observe_eof(&receiver);

        assert!(receiver.is_closed());
        assert!(!receiver.is_empty());
        assert_eq!(state.eof_deadline, None);
    }

    #[tokio::test]
    async fn closed_empty_receiver_does_not_start_finalization_while_replay_is_pending() {
        let (sender, receiver) = mpsc::channel(1);
        drop(sender);
        let mut state = ChannelState::new(0);
        state.pending.restore(tenth_second_chunk(0, 9));

        state.observe_eof(&receiver);

        assert!(receiver.is_closed());
        assert!(receiver.is_empty());
        assert!(!state.pending.is_empty());
        assert_eq!(state.eof_deadline, None);
    }

    #[test]
    fn reconnects_assign_new_session_speaker_ids_instead_of_merging_provider_slots() {
        let payload = json!({ "result": { "utterances": [
            { "text": "voice", "start_time": 0.0, "end_time": 500.0, "definite": true, "additions": { "speaker": "1" } }
        ]}});
        let base = segments_from_payload(&payload, 0, false).remove(0);
        let mut registry = SpeakerRegistry::default();
        let first = registry.relabel(base.clone(), 1);
        let same_connection = registry.relabel(base.clone(), 1);
        let reconnected = registry.relabel(base, 2);

        assert_eq!((first.speaker, same_connection.speaker), (0, 0));
        assert_eq!(first.label, "Remote 1");
        assert_eq!(reconnected.speaker, 1);
        assert_eq!(reconnected.label, "Remote 2");
    }

    #[test]
    fn cross_channel_reconnect_skew_is_written_in_absolute_timestamp_order() {
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        writer
            .append(&Segment {
                channel: 0,
                speaker: 0,
                label: "Remote 1".into(),
                text: "later remote".into(),
                start: 20.0,
                end: 21.0,
            })
            .unwrap();
        writer
            .append(&Segment {
                channel: 1,
                speaker: 0,
                label: "In room 1".into(),
                text: "earlier recovered room".into(),
                start: 10.0,
                end: 11.0,
            })
            .unwrap();
        writer.flush_all().unwrap();

        let content = fs::read_to_string(transcript).unwrap();
        assert!(
            content.find("earlier recovered room").unwrap() < content.find("later remote").unwrap(),
            "replayed older room audio must not be appended after newer remote audio"
        );
    }

    #[test]
    fn silent_channel_acknowledgements_advance_the_live_cross_channel_barrier() {
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        writer.set_active_channels([true, true]);
        let one_hour_frame = (SAMPLE_RATE * 60 * 60) as f64;
        writer
            .append(&Segment {
                channel: 1,
                speaker: 0,
                label: "In room 1".into(),
                text: "audible microphone".into(),
                start: one_hour_frame / SAMPLE_RATE as f64 - 1.0,
                end: one_hour_frame / SAMPLE_RATE as f64 - 0.5,
            })
            .unwrap();
        writer
            .advance(1, one_hour_frame / SAMPLE_RATE as f64 + 1.0)
            .unwrap();
        assert!(!fs::read_to_string(&transcript)
            .unwrap()
            .contains("audible microphone"));

        let silent_audio = AudioChunk {
            data: vec![0; MONO_FRAME_BYTES],
            start_frame: one_hour_frame as usize,
        };
        let mut in_flight = InFlightAudio::default();
        in_flight.record(2, silent_audio, false);
        let acknowledgement = apply_server_confirmation(
            &ServerMessage::Acknowledgement { sequence: 2 },
            &mut in_flight,
            false,
        );
        writer
            .advance_from_confirmation(0, &acknowledgement)
            .unwrap();

        assert!(fs::read_to_string(&transcript)
            .unwrap()
            .contains("audible microphone"));
    }

    #[tokio::test]
    async fn fake_websocket_leading_digital_silence_unblocks_other_channel_without_provider_ack() {
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        transcript_writer.set_active_channels([true, true]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (remote_socket, mut remote_server) = local_websocket_pair().await;
        let (room_socket, mut room_server) = local_websocket_pair().await;
        let (remote_sender, remote_receiver) = mpsc::channel(2);
        let (room_sender, room_receiver) = mpsc::channel(2);
        remote_sender.send(tenth_second_chunk(0, 0)).await.unwrap();
        remote_sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 0))
            .await
            .unwrap();
        room_sender.send(tenth_second_chunk(0, 2)).await.unwrap();
        room_sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 2))
            .await
            .unwrap();
        let (ready, _ready_receiver) = mpsc::channel(2);

        let remote_task = tokio::spawn({
            let writer = writer.clone();
            let ready = ready.clone();
            async move {
                let mut receiver = remote_receiver;
                let mut state = ChannelState::new(0);
                state.connection_id = 1;
                stream_connected_channel(
                    remote_socket,
                    &mut receiver,
                    &writer,
                    None,
                    &ready,
                    "combined",
                    None,
                    &mut state,
                )
                .await
            }
        });
        let room_task = tokio::spawn({
            let writer = writer.clone();
            async move {
                let mut receiver = room_receiver;
                let mut state = ChannelState::new(1);
                state.connection_id = 1;
                stream_connected_channel(
                    room_socket,
                    &mut receiver,
                    &writer,
                    None,
                    &ready,
                    "combined",
                    None,
                    &mut state,
                )
                .await
            }
        });
        let remote_response = tokio::spawn(async move {
            assert!(
                tokio::time::timeout(Duration::from_millis(250), remote_server.next())
                    .await
                    .is_err(),
                "leading digital silence must advance locally instead of opening an ASR audio stream"
            );
            std::future::pending::<()>().await;
        });
        let room_response = tokio::spawn(async move {
            assert!(matches!(
                room_server.next().await,
                Some(Ok(Message::Binary(_)))
            ));
            room_server
                .send(result_message(
                    2,
                    false,
                    json!({ "result": { "utterances": [{
                        "text": "live room speech",
                        "start_time": 0.0,
                        "end_time": 50.0,
                        "definite": true,
                        "additions": { "speaker": "1" }
                    }]}}),
                ))
                .await
                .unwrap();
            std::future::pending::<()>().await;
        });

        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if fs::read_to_string(&transcript)
                    .unwrap()
                    .contains("live room speech")
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("a provider-silent channel must not hold live transcript until EOF");
        assert!(
            !remote_sender.is_closed() && !room_sender.is_closed(),
            "the transcript must flush while both audio inputs are still live"
        );

        remote_task.abort();
        room_task.abort();
        remote_response.abort();
        room_response.abort();
    }

    #[tokio::test]
    async fn all_silent_channel_completes_without_sending_audio_or_a_final_packet() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(2);
        sender.send(tenth_second_chunk(0, 0)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 0))
            .await
            .unwrap();
        drop(sender);
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;

        let server_observation = tokio::spawn(async move {
            match tokio::time::timeout(Duration::from_secs(1), server.next()).await {
                Ok(Some(Ok(Message::Binary(_)))) => {
                    panic!("an all-silent channel must not send an ASR audio packet")
                }
                Ok(Some(Ok(Message::Close(_))) | None) | Err(_) => {}
                Ok(Some(Ok(_))) => {}
                Ok(Some(Err(error))) => panic!("fake server failed: {error}"),
            }
        });

        let completed = tokio::time::timeout(
            Duration::from_secs(1),
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            ),
        )
        .await
        .expect("all-silent EOF must complete locally");
        assert_eq!(completed, Ok(true));
        server_observation.await.unwrap();
    }

    #[tokio::test]
    async fn live_sender_does_not_wait_for_sparse_provider_results_between_audio_packets() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(32);
        for index in 0..26 {
            sender
                .send(tenth_second_chunk(index * SAMPLE_RATE / 10, 3))
                .await
                .unwrap();
        }
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        let stream = tokio::spawn(async move {
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            )
            .await
        });

        tokio::time::timeout(Duration::from_secs(3), async {
            for packet_index in 0..25 {
                assert!(
                    matches!(server.next().await, Some(Ok(Message::Binary(_)))),
                    "audio packet {packet_index} must be sent even when the provider has not produced a new result"
                );
            }
        })
        .await
        .expect("sparse ASR results must not impose a 20-packet sender barrier");

        stream.abort();
        drop(sender);
    }

    #[tokio::test]
    async fn replay_backlog_does_not_delay_provider_results_until_all_audio_is_resent() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(1);
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 2;
        state.pending.chunks = (0..30)
            .map(|index| tenth_second_chunk(index * SAMPLE_RATE / 10, 3))
            .collect();

        let response = tokio::spawn(async move {
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            server
                .send(result_message(
                    2,
                    false,
                    json!({ "result": { "utterances": [{
                        "text": "result while replaying",
                        "start_time": 0.0,
                        "end_time": 100.0,
                        "definite": true
                    }]}}),
                ))
                .await
                .unwrap();
            std::future::pending::<()>().await;
        });
        let stream = tokio::spawn(async move {
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            )
            .await
        });

        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                if fs::read_to_string(&transcript)
                    .unwrap()
                    .contains("result while replaying")
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("provider results must be consumed while replay audio remains queued");

        stream.abort();
        response.abort();
        drop(sender);
    }

    #[tokio::test]
    async fn optimized_first_pass_text_is_published_before_vad_finalization() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        let live_snapshot = root.path().join("transcript.md.live.json");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(3);
        sender.send(tenth_second_chunk(0, 3)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 4))
            .await
            .unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 5, 5))
            .await
            .unwrap();
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        let response = tokio::spawn(async move {
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            server
                .send(result_message(
                    2,
                    false,
                    json!({ "result": { "utterances": [{
                        "text": "first-pass words while speaking",
                        "start_time": 0.0,
                        "end_time": 100.0,
                        "definite": false
                    }]}}),
                ))
                .await
                .unwrap();
            std::future::pending::<()>().await;
        });
        let stream = tokio::spawn(async move {
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            )
            .await
        });

        tokio::time::timeout(Duration::from_millis(750), async {
            loop {
                if fs::read_to_string(&live_snapshot)
                    .is_ok_and(|contents| contents.contains("first-pass words while speaking"))
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the optimized first pass must reach the live UI before an 800ms VAD final");
        assert!(
            !fs::read_to_string(&transcript)
                .unwrap()
                .contains("first-pass words while speaking"),
            "tentative text must not be appended to final Markdown"
        );

        stream.abort();
        response.abort();
        drop(sender);
    }

    #[tokio::test]
    async fn a_stalled_live_websocket_send_times_out_instead_of_freezing_the_channel() {
        let error = await_audio_send(
            std::future::pending::<Result<(), &'static str>>(),
            None,
            Duration::from_millis(20),
        )
        .await
        .expect_err("a half-open websocket send must not wait forever");

        assert!(error.contains("timed out"));
        assert!(error.contains("reconnecting"));
    }

    #[tokio::test]
    async fn speech_without_any_provider_progress_reconnects_and_preserves_audio() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(16);
        for index in 0..10 {
            sender
                .send(tenth_second_chunk(index * SAMPLE_RATE / 10, 3))
                .await
                .unwrap();
        }
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        state.live_response_timeout = Duration::from_millis(150);
        let server_task =
            tokio::spawn(async move { while matches!(server.next().await, Some(Ok(_))) {} });

        let result = tokio::time::timeout(
            Duration::from_secs(1),
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            ),
        )
        .await
        .expect("speech on a silent half-open provider must trigger the reconnect watchdog")
        .expect_err("a provider that stops making progress must be reconnected");

        assert!(result.contains("provider response"));
        assert!(result.contains("reconnecting"));
        assert!(
            state.pending.bytes() >= SAMPLE_RATE * MONO_FRAME_BYTES / 10,
            "unconfirmed speech must remain buffered for replay after reconnect"
        );
        assert!(
            !sender.is_closed(),
            "the live audio producer must remain attached"
        );
        server_task.abort();
    }

    #[tokio::test]
    async fn missing_websocket_heartbeat_reconnects_and_preserves_audio() {
        let (socket, _server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(4);
        sender.send(tenth_second_chunk(0, 3)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 3))
            .await
            .unwrap();
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        state.live_response_timeout = Duration::from_secs(60);
        state.heartbeat_interval = Duration::from_millis(50);
        state.heartbeat_timeout = Duration::from_millis(100);

        let result = tokio::time::timeout(
            Duration::from_secs(1),
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            ),
        )
        .await
        .expect("a peer that never answers WebSocket heartbeats must be detected")
        .expect_err("a half-open WebSocket must be reconnected");

        assert!(result.contains("heartbeat"));
        assert!(result.contains("reconnecting"));
        assert!(
            state.pending.bytes() >= SAMPLE_RATE * MONO_FRAME_BYTES / 10,
            "heartbeat recovery must replay all unconfirmed audio"
        );
        assert!(!sender.is_closed(), "the recorder must remain attached");
    }

    #[tokio::test]
    async fn optimized_second_pass_final_keeps_the_live_connection_open() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript, 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(3);
        sender.send(tenth_second_chunk(0, 3)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 4))
            .await
            .unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 5, 5))
            .await
            .unwrap();
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        let (continued_sender, continued_receiver) = tokio::sync::oneshot::channel();
        let response = tokio::spawn(async move {
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            server
                .send(result_message(
                    -2,
                    true,
                    json!({ "result": { "utterances": [{
                        "text": "second-pass sentence",
                        "start_time": 0.0,
                        "end_time": 100.0,
                        "definite": true
                    }]}}),
                ))
                .await
                .unwrap();
            assert!(
                matches!(server.next().await, Some(Ok(Message::Binary(_)))),
                "audio after a per-sentence second-pass final must stay on the same connection"
            );
            let _ = continued_sender.send(());
            std::future::pending::<()>().await;
        });

        let stream = tokio::spawn(async move {
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            )
            .await
        });
        tokio::time::timeout(Duration::from_secs(1), continued_receiver)
            .await
            .expect("the optimized stream must continue sending after a sentence final")
            .unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert!(
            !stream.is_finished(),
            "a two-pass sentence final is not an end-of-session response"
        );
        assert!(!sender.is_closed(), "audio input was still live");
        stream.abort();
        response.abort();
    }

    #[tokio::test]
    async fn cumulative_full_results_append_each_definite_utterance_exactly_once() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(3);
        sender.send(tenth_second_chunk(0, 3)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 4))
            .await
            .unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 5, 5))
            .await
            .unwrap();
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;
        let response = tokio::spawn(async move {
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            server
                .send(result_message(
                    2,
                    false,
                    json!({ "result": { "utterances": [{
                        "text": "first cumulative sentence",
                        "start_time": 0.0,
                        "end_time": 100.0,
                        "definite": true
                    }]}}),
                ))
                .await
                .unwrap();
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            server
                .send(result_message(
                    3,
                    false,
                    json!({ "result": { "utterances": [
                        {
                            "text": "first cumulative sentence",
                            "start_time": 0.0,
                            "end_time": 100.0,
                            "definite": true
                        },
                        {
                            "text": "second cumulative sentence",
                            "start_time": 100.0,
                            "end_time": 200.0,
                            "definite": true
                        }
                    ]}}),
                ))
                .await
                .unwrap();
            std::future::pending::<()>().await;
        });

        let stream = tokio::spawn(async move {
            stream_connected_channel(
                socket,
                &mut receiver,
                &writer,
                None,
                &ready,
                "combined",
                None,
                &mut state,
            )
            .await
        });

        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let contents = fs::read_to_string(&transcript).unwrap();
                if contents.contains("second cumulative sentence") {
                    assert_eq!(contents.matches("first cumulative sentence").count(), 1);
                    assert_eq!(contents.matches("second cumulative sentence").count(), 1);
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("both cumulative definite utterances must be written without duplication");

        stream.abort();
        response.abort();
        drop(sender);
    }

    #[tokio::test]
    async fn provider_final_result_may_arrive_after_the_old_one_point_five_second_window() {
        let (socket, mut server) = local_websocket_pair().await;
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut transcript_writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        transcript_writer.set_active_channels([true, false]);
        let writer = Arc::new(Mutex::new(transcript_writer));
        let (sender, mut receiver) = mpsc::channel(2);
        sender.send(tenth_second_chunk(0, 3)).await.unwrap();
        sender
            .send(tenth_second_chunk(SAMPLE_RATE / 10, 4))
            .await
            .unwrap();
        drop(sender);
        let (ready, _ready_receiver) = mpsc::channel(1);
        let mut state = ChannelState::new(0);
        state.connection_id = 1;

        let response = tokio::spawn(async move {
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            assert!(matches!(server.next().await, Some(Ok(Message::Binary(_)))));
            tokio::time::sleep(Duration::from_millis(1_600)).await;
            server
                .send(result_message(
                    -3,
                    true,
                    json!({ "result": { "utterances": [{
                        "text": "provider finished after network jitter",
                        "start_time": 0.0,
                        "end_time": 200.0,
                        "definite": true,
                        "additions": { "speaker": "1" }
                    }]}}),
                ))
                .await
                .unwrap();
        });

        let completed = stream_connected_channel(
            socket,
            &mut receiver,
            &writer,
            None,
            &ready,
            "combined",
            None,
            &mut state,
        )
        .await;
        response.await.unwrap();

        assert_eq!(completed, Ok(true));
        assert!(
            fs::read_to_string(transcript)
                .unwrap()
                .contains("provider finished after network jitter"),
            "a valid provider final result must be persisted before shutdown"
        );
    }

    #[test]
    fn disabled_channel_never_holds_the_live_cross_channel_barrier() {
        let root = tempfile::tempdir().unwrap();
        let transcript = root.path().join("transcript.md");
        fs::write(&transcript, "# Meeting\n\n").unwrap();
        let mut writer = TranscriptWriter::new(transcript.clone(), 0.0).unwrap();
        writer.set_active_channels([true, false]);
        writer
            .append(&Segment {
                channel: 0,
                speaker: 0,
                label: "Remote 1".into(),
                text: "system-only audio".into(),
                start: 10.0,
                end: 11.0,
            })
            .unwrap();
        writer.advance(0, 12.0).unwrap();

        assert!(fs::read_to_string(transcript)
            .unwrap()
            .contains("system-only audio"));
    }

    #[test]
    fn audio_buffer_capacity_is_configurable_but_strictly_bounded() {
        assert_eq!(audio_buffer_capacity(None), 300);
        assert_eq!(audio_buffer_capacity(Some(0)), 5);
        assert_eq!(audio_buffer_capacity(Some(1)), 5);
        assert_eq!(audio_buffer_capacity(Some(61)), 305);
        assert_eq!(audio_buffer_capacity(Some(usize::MAX)), 1_500);
    }

    #[test]
    fn reconnect_backoff_is_exponential_and_capped() {
        let mut delay = 1;
        let mut observed = Vec::new();
        for _ in 0..8 {
            observed.push(delay);
            delay = next_retry_delay(delay);
        }
        assert_eq!(observed, [1, 2, 4, 8, 15, 15, 15, 15]);
    }

    #[test]
    fn transport_failures_retry_but_provider_rejections_remain_fatal() {
        assert!(!is_fatal_channel_error(
            "Doubao connection failed: failed to lookup address information"
        ));
        assert!(!is_fatal_channel_error(
            "Doubao stream dropped: Connection reset by peer"
        ));
        assert!(is_fatal_channel_error(
            "Doubao transcription failed (45000000): invalid access token"
        ));
        assert!(is_fatal_channel_error(
            "Doubao connection failed: HTTP error: 401 Unauthorized"
        ));
    }

    #[test]
    fn reconnect_results_keep_absolute_channel_time_for_deduplication() {
        let payload = json!({ "result": { "utterances": [
            { "text": "same words", "start_time": 250.0, "end_time": 750.0, "definite": true }
        ]}});
        let first = segments_from_connection_payload(&payload, 1, false, 12.0).remove(0);
        let replay = segments_from_connection_payload(&payload, 1, false, 12.0).remove(0);
        let later = segments_from_connection_payload(&payload, 1, false, 20.0).remove(0);

        assert_eq!((first.channel, first.start, first.end), (1, 12.25, 12.75));
        assert_eq!(segment_dedup_key(&first), segment_dedup_key(&replay));
        assert_ne!(segment_dedup_key(&first), segment_dedup_key(&later));
    }
}
