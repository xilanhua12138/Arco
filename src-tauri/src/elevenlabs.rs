use crate::speaker_timeline::wait_for_speaker;
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chrono::{Local, TimeZone};
use futures_util::{Sink, SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::fs::{self, File, OpenOptions};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, Stdin};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

const SAMPLE_RATE: usize = 16_000;
const STEREO_FRAME_BYTES: usize = 4;
const MONO_FRAME_BYTES: usize = 2;
const READ_CHUNK_BYTES: usize = 6_400;
const DEFAULT_BUFFER_SECONDS: usize = 60;
const SPEAKER_TIMELINE_WAIT: Duration = Duration::from_millis(1_500);
const REALTIME_MODEL: &str = "scribe_v2_realtime";
const REALTIME_ENDPOINT: &str = "wss://api.elevenlabs.io/v1/speech-to-text/realtime";
const MAX_REPLAY_RATE_NUMERATOR: u128 = 5;
const MAX_REPLAY_RATE_DENOMINATOR: u128 = 4;
const MAX_PREVIOUS_TEXT_CHARS: usize = 50;
const FATAL_ERROR_PREFIX: &str = "ARCO_ELEVENLABS_FATAL:";

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub channel: usize,
    pub speaker: i64,
    pub label: String,
    pub text: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct AudioChunk {
    data: Vec<u8>,
    start_frame: usize,
}

impl AudioChunk {
    fn end_frame(&self) -> usize {
        self.start_frame + self.data.len() / MONO_FRAME_BYTES
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct ProviderError {
    message_type: String,
    message: String,
    fatal: bool,
}

fn provider_error_from_payload(payload: &Value) -> Option<ProviderError> {
    const FATAL: &[&str] = &[
        "auth_error",
        "quota_exceeded",
        "input_error",
        "unaccepted_terms",
        "chunk_size_exceeded",
    ];
    const RETRYABLE: &[&str] = &[
        "transcriber_error",
        "commit_throttled",
        "rate_limited",
        "queue_overflow",
        "resource_exhausted",
        "session_time_limit_exceeded",
        "insufficient_audio_activity",
        "error",
    ];
    let raw_type = payload
        .get("message_type")
        .or_else(|| payload.get("type"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    let message_type =
        if FATAL.contains(&raw_type.as_str()) || RETRYABLE.contains(&raw_type.as_str()) {
            raw_type
        } else if payload.get("error").is_some() {
            "error".into()
        } else {
            return None;
        };
    let message = payload
        .get("error")
        .and_then(|value| {
            value.as_str().map(str::to_string).or_else(|| {
                value
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
        })
        .or_else(|| {
            payload
                .get("message")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| format!("ElevenLabs returned {message_type}"));
    Some(ProviderError {
        fatal: FATAL.contains(&message_type.as_str()),
        message_type,
        message,
    })
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

fn previous_text_context(text: &str) -> String {
    let characters: Vec<char> = text.chars().collect();
    characters[characters.len().saturating_sub(MAX_PREVIOUS_TEXT_CHARS)..]
        .iter()
        .collect()
}

fn audio_chunk_message(chunk: &AudioChunk, previous_text: Option<&str>, commit: bool) -> Value {
    let mut message = json!({
        "message_type": "input_audio_chunk",
        "audio_base_64": BASE64.encode(&chunk.data),
        "sample_rate": SAMPLE_RATE,
        "commit": commit,
    });
    if let Some(previous_text) = previous_text.filter(|text| !text.is_empty()) {
        message["previous_text"] = Value::String(previous_text.into());
    }
    message
}

async fn send_audio_chunk<S>(
    sink: &mut S,
    chunk: &AudioChunk,
    pacer: &mut Option<ReplayPacer>,
    connection_started: Instant,
    previous_text: &str,
    sent_first_audio: &mut bool,
) -> Result<(), S::Error>
where
    S: Sink<Message> + Unpin,
{
    let pacer = pacer.get_or_insert_with(|| ReplayPacer::new(chunk));
    let delay = pacer.delay_for(chunk, connection_started.elapsed());
    if !delay.is_zero() {
        tokio::time::sleep(delay).await;
    }
    let context = (!*sent_first_audio).then_some(previous_text);
    let message = audio_chunk_message(chunk, context, false);
    sink.send(Message::Text(message.to_string().into())).await?;
    *sent_first_audio = true;
    Ok(())
}

fn buffered_audio_seconds(pending: &PendingAudio, receiver: &mpsc::Receiver<AudioChunk>) -> f64 {
    let bytes = pending.bytes() + receiver.len() * (READ_CHUNK_BYTES / 2);
    bytes as f64 / (SAMPLE_RATE * MONO_FRAME_BYTES) as f64
}

fn mark_channel_ready(
    ready_channels: &AtomicUsize,
    expected_ready_channels: usize,
    announced: &mut bool,
) -> bool {
    if *announced {
        return false;
    }
    *announced = true;
    ready_channels.fetch_add(1, Ordering::SeqCst) + 1 == expected_ready_channels
}

#[derive(Clone, Debug, PartialEq)]
struct LogprobObservation {
    channel: usize,
    word_count: usize,
    average: f64,
    minimum: f64,
}

impl LogprobObservation {
    fn from_realtime(payload: &Value, channel: usize) -> Option<Self> {
        if payload.get("message_type").and_then(Value::as_str)
            != Some("committed_transcript_with_timestamps")
        {
            return None;
        }
        let logprobs: Vec<f64> = payload
            .get("words")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|word| word.get("type").and_then(Value::as_str) == Some("word"))
            .filter_map(|word| word.get("logprob").and_then(Value::as_f64))
            .filter(|logprob| logprob.is_finite())
            .collect();
        if logprobs.is_empty() {
            return None;
        }
        Some(Self {
            channel,
            word_count: logprobs.len(),
            average: logprobs.iter().sum::<f64>() / logprobs.len() as f64,
            minimum: logprobs.iter().copied().reduce(f64::min)?,
        })
    }

    fn log(&self) {
        eprintln!(
            "ARCO_TRANSCRIPTION_QUALITY provider=elevenlabs channel={} confidence_words={} average_logprob={:.4} minimum_logprob={:.4}",
            self.channel, self.word_count, self.average, self.minimum
        );
    }
}

pub fn realtime_url(language: &str) -> String {
    let language = match language {
        "zh-CN" | "zh-Hans" | "zh" => Some("zh"),
        "en-US" | "en" => Some("en"),
        _ => None,
    };
    let mut url = format!(
        "{REALTIME_ENDPOINT}?model_id={REALTIME_MODEL}&audio_format=pcm_16000&include_timestamps=true&commit_strategy=vad&vad_silence_threshold_secs=1.5"
    );
    if let Some(language) = language {
        url.push_str("&language_code=");
        url.push_str(language);
    }
    url
}

pub fn payload_error(payload: &Value) -> Option<String> {
    provider_error_from_payload(payload).map(|error| error.message)
}

pub fn segments_from_realtime(payload: &Value, channel: usize) -> Vec<Segment> {
    if payload.get("message_type").and_then(Value::as_str)
        != Some("committed_transcript_with_timestamps")
    {
        return Vec::new();
    }
    let text = payload
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if text.is_empty() {
        return Vec::new();
    }
    let words = payload
        .get("words")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let start = words
        .iter()
        .find_map(|word| word.get("start").and_then(Value::as_f64))
        .unwrap_or(0.0);
    let end = words
        .iter()
        .rev()
        .find_map(|word| word.get("end").and_then(Value::as_f64))
        .unwrap_or(start);
    vec![Segment {
        channel,
        speaker: 0,
        label: source_label(channel),
        text: text.into(),
        start,
        end: end.max(start),
    }]
}

async fn attribute_segment(mut segment: Segment, timeline_path: Option<&Path>) -> Segment {
    let Some(path) = timeline_path else {
        return segment;
    };
    let speaker = wait_for_speaker(
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
        speaker + 1,
    );
    segment
}

fn source_label(channel: usize) -> String {
    if channel == 0 {
        "Remote 1".into()
    } else {
        "In room 1".into()
    }
}

struct TranscriptWriter {
    path: PathBuf,
    session_started_at: f64,
}

impl TranscriptWriter {
    fn new(path: PathBuf, session_started_at: f64) -> Result<Self, String> {
        if !path.exists() {
            return Err(
                "The desktop host must initialize the transcript before transcription".into(),
            );
        }
        Ok(Self {
            path,
            session_started_at,
        })
    }

    fn append(&self, segment: &Segment) -> Result<(), String> {
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
        writeln!(
            file,
            "**[{timestamp}] {}:** {}\n",
            segment.label, segment.text
        )
        .and_then(|_| {
            writeln!(
                file,
                "<!-- arco channel={} speaker={} stream=elevenlabs-realtime start={:.3} end={:.3} -->\n",
                segment.channel, segment.speaker, segment.start, segment.end,
            )
        })
        .and_then(|_| file.flush())
        .map_err(|error| format!("could not write live ElevenLabs transcript: {error}"))
    }
}

fn split_stereo_pcm(data: &[u8]) -> (Vec<u8>, Vec<u8>) {
    let frames = data.len() / STEREO_FRAME_BYTES;
    let mut remote = Vec::with_capacity(frames * 2);
    let mut room = Vec::with_capacity(frames * 2);
    for frame in data.chunks_exact(STEREO_FRAME_BYTES) {
        remote.extend_from_slice(&frame[..2]);
        room.extend_from_slice(&frame[2..]);
    }
    (remote, room)
}

#[derive(Default)]
struct StereoChunker {
    carry: Vec<u8>,
}

impl StereoChunker {
    fn push(&mut self, data: &[u8]) -> Vec<Vec<u8>> {
        self.carry.extend_from_slice(data);
        let complete_bytes = self.carry.len() / READ_CHUNK_BYTES * READ_CHUNK_BYTES;
        if complete_bytes == 0 {
            return Vec::new();
        }
        let tail = self.carry.split_off(complete_bytes);
        let complete = std::mem::replace(&mut self.carry, tail);
        complete
            .chunks_exact(READ_CHUNK_BYTES)
            .map(<[u8]>::to_vec)
            .collect()
    }

    fn finish(&mut self) -> Vec<Vec<u8>> {
        let aligned = self.carry.len() / STEREO_FRAME_BYTES * STEREO_FRAME_BYTES;
        if aligned == 0 {
            self.carry.clear();
            return Vec::new();
        }
        let chunk = self.carry[..aligned].to_vec();
        self.carry.clear();
        vec![chunk]
    }
}

async fn pump_stdin(
    mut input: Stdin,
    senders: [mpsc::Sender<AudioChunk>; 2],
) -> Result<(), String> {
    let mut next_frame = 0usize;
    let mut chunker = StereoChunker::default();
    loop {
        let mut buffer = vec![0u8; READ_CHUNK_BYTES];
        let read = input
            .read(&mut buffer)
            .await
            .map_err(|error| format!("could not read native audio: {error}"))?;
        if read == 0 {
            break;
        }
        for data in chunker.push(&buffer[..read]) {
            let frames = data.len() / STEREO_FRAME_BYTES;
            let (remote, room) = split_stereo_pcm(&data);
            for (sender, channel) in senders.iter().zip([remote, room]) {
                let _ = sender
                    .send(AudioChunk {
                        data: channel,
                        start_frame: next_frame,
                    })
                    .await;
            }
            next_frame += frames;
        }
    }
    for data in chunker.finish() {
        let (remote, room) = split_stereo_pcm(&data);
        for (sender, channel) in senders.iter().zip([remote, room]) {
            let _ = sender
                .send(AudioChunk {
                    data: channel,
                    start_frame: next_frame,
                })
                .await;
        }
    }
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
    file.write_all(b"elevenlabs-ready\n")
        .and_then(|_| file.sync_all())
        .map_err(|error| error.to_string())?;
    fs::rename(&temporary, &path).map_err(|error| error.to_string())
}

async fn connect_socket(
    api_key: &str,
    language: &str,
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    String,
> {
    let mut request = realtime_url(language)
        .into_client_request()
        .map_err(|error| format!("invalid ElevenLabs request: {error}"))?;
    request.headers_mut().insert(
        "xi-api-key",
        HeaderValue::from_str(api_key)
            .map_err(|_| "invalid ElevenLabs credential header".to_string())?,
    );
    connect_async(request)
        .await
        .map(|(socket, _)| socket)
        .map_err(|error| format!("ElevenLabs connection failed: {error}"))
}

async fn stream_connected_channel(
    socket: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    receiver: &mut mpsc::Receiver<AudioChunk>,
    writer: &Arc<Mutex<TranscriptWriter>>,
    timeline_path: Option<&Path>,
    ready_channels: &AtomicUsize,
    expected_ready_channels: usize,
    state: &mut RealtimeChannelState,
) -> Result<bool, String> {
    let replay_buffered_seconds = buffered_audio_seconds(&state.pending, receiver);
    let (mut sink, mut stream) = socket.split();
    if state.connection_id > 1 {
        eprintln!(
            "ARCO_ELEVENLABS_RECONNECT channel={} connection={} buffered_audio={:.3}s pending_bytes={} max_replay_rate=1.25",
            state.channel,
            state.connection_id,
            replay_buffered_seconds,
            state.pending.bytes(),
        );
    }
    let mut connection_origin: Option<f64> = None;
    let connection_started = Instant::now();
    let connection_context = previous_text_context(&state.recent_text);
    let mut sent_first_audio = false;
    let mut pacer = None;
    let mut replay_reported = state.connection_id == 1 || replay_buffered_seconds == 0.0;
    let mut closing = false;
    let close_deadline = tokio::time::sleep(Duration::from_secs(365 * 24 * 60 * 60));
    tokio::pin!(close_deadline);
    loop {
        if !closing {
            if let Some(chunk) = state.pending.take() {
                connection_origin.get_or_insert(chunk.start_frame as f64 / SAMPLE_RATE as f64);
                if let Err(error) = send_audio_chunk(
                    &mut sink,
                    &chunk,
                    &mut pacer,
                    connection_started,
                    &connection_context,
                    &mut sent_first_audio,
                )
                .await
                {
                    state.pending.restore(chunk);
                    return Err(format!("ElevenLabs replay send failed: {error}"));
                }
                if !replay_reported && receiver.is_empty() {
                    eprintln!(
                        "ARCO_ELEVENLABS_REPLAY_CAUGHT_UP channel={} connection={} replayed_audio={:.3}s",
                        state.channel, state.connection_id, replay_buffered_seconds
                    );
                    replay_reported = true;
                }
                continue;
            }
        }
        tokio::select! {
            chunk = receiver.recv(), if !closing => {
                match chunk {
                    Some(chunk) => {
                        connection_origin.get_or_insert(chunk.start_frame as f64 / SAMPLE_RATE as f64);
                        if let Err(error) = send_audio_chunk(
                            &mut sink,
                            &chunk,
                            &mut pacer,
                            connection_started,
                            &connection_context,
                            &mut sent_first_audio,
                        ).await {
                            state.pending.restore(chunk);
                            return Err(format!("ElevenLabs audio send failed: {error}"));
                        }
                        if !replay_reported && receiver.is_empty() {
                            eprintln!(
                                "ARCO_ELEVENLABS_REPLAY_CAUGHT_UP channel={} connection={} replayed_audio={:.3}s",
                                state.channel, state.connection_id, replay_buffered_seconds
                            );
                            replay_reported = true;
                        }
                    }
                    None => {
                        closing = true;
                        close_deadline.as_mut().reset(
                            tokio::time::Instant::now() + Duration::from_secs(4),
                        );
                        let commit = json!({
                            "message_type": "input_audio_chunk",
                            "audio_base_64": "",
                            "sample_rate": SAMPLE_RATE,
                            "commit": true,
                        });
                        sink.send(Message::Text(commit.to_string().into())).await
                            .map_err(|error| format!("ElevenLabs final realtime commit failed: {error}"))?;
                    }
                }
            }
            message = stream.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        let Ok(payload) = serde_json::from_str::<Value>(&text) else { continue };
                        if let Some(error) = provider_error_from_payload(&payload) {
                            let message = format!(
                                "ElevenLabs {}: {}",
                                error.message_type, error.message
                            );
                            return Err(if error.fatal {
                                format!("{FATAL_ERROR_PREFIX}{message}")
                            } else {
                                message
                            });
                        }
                        if payload.get("message_type").and_then(Value::as_str) == Some("session_started") {
                            if mark_channel_ready(
                                ready_channels,
                                expected_ready_channels,
                                &mut state.ready_announced,
                            ) {
                                signal_ready()?;
                            }
                            continue;
                        }
                        if let Some(observation) = LogprobObservation::from_realtime(&payload, state.channel) {
                            observation.log();
                        }
                        let origin = connection_origin.unwrap_or(0.0);
                        for mut segment in segments_from_realtime(&payload, state.channel) {
                            segment.start += origin;
                            segment.end += origin;
                            let segment = attribute_segment(segment, timeline_path).await;
                            writer.lock().await.append(&segment)?;
                            state.recent_text = segment.text;
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => return Ok(closing),
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(format!("ElevenLabs stream dropped: {error}")),
                }
            }
            _ = &mut close_deadline, if closing => {
                let _ = sink.send(Message::Close(None)).await;
                return Ok(true);
            }
        }
    }
}

#[derive(Clone)]
struct RealtimeSession<'a> {
    api_key: &'a str,
    language: &'a str,
    writer: Arc<Mutex<TranscriptWriter>>,
    timeline_path: Option<PathBuf>,
    ready_channels: Arc<AtomicUsize>,
    expected_ready_channels: usize,
}

struct RealtimeChannelState {
    pending: PendingAudio,
    recent_text: String,
    ready_announced: bool,
    channel: usize,
    connection_id: u64,
}

impl RealtimeChannelState {
    fn new(channel: usize) -> Self {
        Self {
            pending: PendingAudio::default(),
            recent_text: String::new(),
            ready_announced: false,
            channel,
            connection_id: 0,
        }
    }
}

async fn run_realtime_channel(
    session: RealtimeSession<'_>,
    mut receiver: mpsc::Receiver<AudioChunk>,
    channel: usize,
    enabled: bool,
) -> Result<(), String> {
    if !enabled {
        while receiver.recv().await.is_some() {}
        return Ok(());
    }
    let mut state = RealtimeChannelState::new(channel);
    let mut retry = 1u64;
    loop {
        state.connection_id += 1;
        match connect_socket(session.api_key, session.language).await {
            Ok(socket) => {
                match stream_connected_channel(
                    socket,
                    &mut receiver,
                    &session.writer,
                    session.timeline_path.as_deref(),
                    &session.ready_channels,
                    session.expected_ready_channels,
                    &mut state,
                )
                .await
                {
                    Ok(true) => return Ok(()),
                    Ok(false) => {}
                    Err(error)
                        if error.contains("HTTP 401")
                            || error.contains("HTTP 403")
                            || error.starts_with(FATAL_ERROR_PREFIX) =>
                    {
                        return Err(error.trim_start_matches(FATAL_ERROR_PREFIX).to_string());
                    }
                    Err(error) => {
                        eprintln!(
                            "[elevenlabs channel {channel}] {error}; retrying in {retry}s; buffered_audio={:.3}s pending_bytes={}",
                            buffered_audio_seconds(&state.pending, &receiver),
                            state.pending.bytes(),
                        )
                    }
                }
            }
            Err(error) if error.contains("HTTP 401") || error.contains("HTTP 403") => {
                return Err(error);
            }
            Err(error) => eprintln!(
                "[elevenlabs channel {channel}] {error}; retrying in {retry}s; buffered_audio={:.3}s pending_bytes={}",
                buffered_audio_seconds(&state.pending, &receiver),
                state.pending.bytes(),
            ),
        }
        if receiver.is_closed() && receiver.is_empty() {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_secs(retry)).await;
        retry = (retry * 2).min(15);
    }
}

fn active_channels_for_mode(mode: &str) -> [bool; 2] {
    match mode {
        "system" => [true, false],
        "mic" => [false, true],
        _ => [true, true],
    }
}

async fn run_realtime_pipeline<P, R, L>(pump: P, remote: R, room: L) -> Result<(), String>
where
    P: Future<Output = Result<(), String>>,
    R: Future<Output = Result<(), String>>,
    L: Future<Output = Result<(), String>>,
{
    tokio::try_join!(pump, remote, room)?;
    Ok(())
}

pub async fn run_transcriber(transcript_path: &Path) -> Result<(), String> {
    let api_key = std::env::var("ELEVENLABS_API_KEY").unwrap_or_default();
    if api_key.trim().is_empty() {
        return Err("ElevenLabs is not configured in Arco Settings.".into());
    }
    let language = std::env::var("ELEVENLABS_LANG").unwrap_or_else(|_| "auto".into());
    let active_channels = active_channels_for_mode(
        &std::env::var("ARCO_AUDIO_MODE").unwrap_or_else(|_| "both".into()),
    );
    let expected_ready_channels = active_channels.iter().filter(|&&enabled| enabled).count();
    let session_started_at = std::env::var("ARCO_SESSION_STARTED_AT_UNIX")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| chrono::Utc::now().timestamp_millis() as f64 / 1000.0);
    let writer = Arc::new(Mutex::new(TranscriptWriter::new(
        transcript_path.to_path_buf(),
        session_started_at,
    )?));
    let timeline_path = std::env::var_os("ARCO_SPEAKER_TIMELINE_FILE").map(PathBuf::from);
    let buffer_seconds = std::env::var("ARCO_AUDIO_BUFFER_SECONDS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_BUFFER_SECONDS)
        .clamp(1, 300);
    let capacity = buffer_seconds * 10;
    let (remote_sender, remote_receiver) = mpsc::channel(capacity);
    let (room_sender, room_receiver) = mpsc::channel(capacity);
    let realtime_session = RealtimeSession {
        api_key: api_key.trim(),
        language: &language,
        writer,
        timeline_path,
        ready_channels: Arc::new(AtomicUsize::new(0)),
        expected_ready_channels,
    };

    let pump = pump_stdin(tokio::io::stdin(), [remote_sender, room_sender]);
    let remote = run_realtime_channel(
        realtime_session.clone(),
        remote_receiver,
        0,
        active_channels[0],
    );
    let room = run_realtime_channel(realtime_session, room_receiver, 1, active_channels[1]);
    run_realtime_pipeline(pump, remote, room).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn realtime_contract_is_mono_timestamped_and_never_claims_speaker_diarization() {
        let url = realtime_url("zh-CN");
        for expected in [
            "model_id=scribe_v2_realtime",
            "audio_format=pcm_16000",
            "include_timestamps=true",
            "commit_strategy=vad",
            "vad_silence_threshold_secs=1.5",
            "language_code=zh",
        ] {
            assert!(url.contains(expected), "missing {expected} from {url}");
        }
        assert!(!url.contains("diar"));
        assert!(!url.contains("channels"));
        assert!(!url.contains("filter_background_audio"));
        assert!(!realtime_url("auto").contains("language_code"));
    }

    #[test]
    fn official_error_events_are_classified_without_treating_session_start_as_failure() {
        for message_type in [
            "auth_error",
            "quota_exceeded",
            "input_error",
            "unaccepted_terms",
            "chunk_size_exceeded",
        ] {
            assert_eq!(
                provider_error_from_payload(&json!({
                    "message_type": message_type,
                    "message": "rejected"
                })),
                Some(ProviderError {
                    message_type: message_type.into(),
                    message: "rejected".into(),
                    fatal: true,
                }),
                "{message_type} must stop retrying"
            );
        }
        for message_type in [
            "transcriber_error",
            "commit_throttled",
            "rate_limited",
            "queue_overflow",
            "resource_exhausted",
            "session_time_limit_exceeded",
            "insufficient_audio_activity",
            "error",
        ] {
            assert_eq!(
                provider_error_from_payload(&json!({
                    "message_type": message_type,
                    "message": "retry later"
                })),
                Some(ProviderError {
                    message_type: message_type.into(),
                    message: "retry later".into(),
                    fatal: false,
                }),
                "{message_type} must remain retryable"
            );
        }
        assert_eq!(
            provider_error_from_payload(&json!({"message_type":"session_started"})),
            None
        );
    }

    #[test]
    fn channel_readiness_requires_each_session_started_event_exactly_once() {
        let ready = AtomicUsize::new(0);
        let mut remote_announced = false;
        let mut room_announced = false;

        assert!(!mark_channel_ready(&ready, 2, &mut remote_announced));
        assert!(!mark_channel_ready(&ready, 2, &mut remote_announced));
        assert_eq!(ready.load(Ordering::SeqCst), 1);
        assert!(mark_channel_ready(&ready, 2, &mut room_announced));
        assert_eq!(ready.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn reconnect_context_is_recent_unicode_safe_and_only_added_to_the_first_chunk() {
        let text =
            "开场内容已经很长，应当只保留最新的上下文。The latest product name is Arco Realtime.";
        let context = previous_text_context(text);
        assert!(context.chars().count() <= 50);
        assert!(context.ends_with("Arco Realtime."));

        let chunk = AudioChunk {
            data: vec![1, 2, 3, 4],
            start_frame: 42,
        };
        let first = audio_chunk_message(&chunk, Some(&context), false);
        let second = audio_chunk_message(&chunk, None, false);
        assert_eq!(
            first.get("previous_text").and_then(Value::as_str),
            Some(context.as_str())
        );
        assert_eq!(second.get("previous_text"), None);
        assert_eq!(first.get("commit").and_then(Value::as_bool), Some(false));
    }

    #[test]
    fn reconnect_pacer_preserves_realtime_and_caps_large_backlogs() {
        let first = AudioChunk {
            data: vec![1; READ_CHUNK_BYTES / 2],
            start_frame: 16_000,
        };
        let pacer = ReplayPacer::new(&first);
        assert_eq!(pacer.delay_for(&first, Duration::ZERO), Duration::ZERO);
        let second = AudioChunk {
            data: vec![2; READ_CHUNK_BYTES / 2],
            start_frame: first.end_frame(),
        };
        assert_eq!(
            pacer.delay_for(&second, Duration::ZERO),
            Duration::from_millis(80)
        );
        assert_eq!(
            pacer.delay_for(&second, Duration::from_millis(100)),
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

    #[tokio::test]
    async fn failed_chunk_is_retried_before_new_channel_audio_without_mutation() {
        let failed = AudioChunk {
            data: vec![7, 8, 9, 10],
            start_frame: 4_200,
        };
        let newer = AudioChunk {
            data: vec![11, 12, 13, 14],
            start_frame: 4_202,
        };
        let (sender, mut receiver) = mpsc::channel(2);
        sender.send(newer.clone()).await.unwrap();
        drop(sender);
        let mut pending = PendingAudio::default();
        pending.restore(failed.clone());

        assert_eq!(pending.take(), Some(failed));
        assert_eq!(receiver.recv().await, Some(newer));
        assert_eq!(pending.take(), None);
        assert_eq!(receiver.recv().await, None);
    }

    #[test]
    fn realtime_logprob_observation_uses_words_only_and_handles_missing_values() {
        let payload = json!({
            "message_type": "committed_transcript_with_timestamps",
            "text": "hello world",
            "words": [
                {"text":"hello", "type":"word", "logprob":-0.05},
                {"text":" ", "type":"spacing"},
                {"text":"world", "type":"word", "logprob":-1.0}
            ]
        });
        assert_eq!(
            LogprobObservation::from_realtime(&payload, 1),
            Some(LogprobObservation {
                channel: 1,
                word_count: 2,
                average: -0.525,
                minimum: -1.0,
            })
        );
        assert_eq!(
            LogprobObservation::from_realtime(
                &json!({
                    "message_type":"committed_transcript_with_timestamps",
                    "text":"silence",
                    "words":[]
                }),
                0,
            ),
            None
        );
        assert_eq!(
            LogprobObservation::from_realtime(
                &json!({"message_type":"partial_transcript", "words":[{"logprob":-0.1}]}),
                0,
            ),
            None
        );
    }

    #[test]
    fn stereo_recorder_frames_are_split_without_crossing_sources() {
        let (remote, room) = split_stereo_pcm(&[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(remote, vec![1, 2, 5, 6]);
        assert_eq!(room, vec![3, 4, 7, 8]);
    }

    #[test]
    fn fragmented_pipe_reads_are_reassembled_into_recommended_hundred_ms_chunks() {
        let payload: Vec<u8> = (0..READ_CHUNK_BYTES * 2 + 5)
            .map(|index| (index % 251) as u8)
            .collect();
        let mut chunker = StereoChunker::default();

        assert!(chunker.push(&payload[..997]).is_empty());
        let first = chunker.push(&payload[997..READ_CHUNK_BYTES + 13]);
        assert_eq!(first, vec![payload[..READ_CHUNK_BYTES].to_vec()]);
        let second = chunker.push(&payload[READ_CHUNK_BYTES + 13..]);
        assert_eq!(
            second,
            vec![payload[READ_CHUNK_BYTES..READ_CHUNK_BYTES * 2].to_vec()]
        );
        assert_eq!(
            chunker.finish(),
            vec![payload[READ_CHUNK_BYTES * 2..READ_CHUNK_BYTES * 2 + 4].to_vec()],
            "the trailing non-frame byte must be discarded without inventing audio"
        );
    }

    #[test]
    fn realtime_commits_keep_source_labels_but_never_invent_speaker_identities() {
        let payload = json!({
            "message_type": "committed_transcript_with_timestamps",
            "text": "Hello from the room.",
            "words": [
                {"text":"Hello", "type":"word", "start":0.1, "end":0.4},
                {"text":"room.", "type":"word", "start":0.5, "end":0.8}
            ]
        });
        let segments = segments_from_realtime(&payload, 1);
        assert_eq!(segments.len(), 1);
        assert_eq!(segments[0].label, "In room 1");
        assert_eq!(segments[0].text, "Hello from the room.");
    }

    #[tokio::test]
    async fn an_independent_streaming_diarizer_can_label_elevenlabs_asr_segments() {
        let root = tempfile::tempdir().unwrap();
        let timeline_path = root.path().join("speaker-timeline.json");
        let mut timeline =
            crate::speaker_timeline::SpeakerTimelineStore::new(timeline_path.clone());
        timeline
            .update(
                1,
                1.0,
                vec![crate::speaker_timeline::SpeakerInterval {
                    speaker: 2,
                    start: 0.0,
                    end: 1.0,
                }],
                vec![],
            )
            .unwrap();
        let segment = Segment {
            channel: 1,
            speaker: 0,
            label: "In room 1".into(),
            text: "Hello".into(),
            start: 0.1,
            end: 0.9,
        };

        let attributed = attribute_segment(segment, Some(&timeline_path)).await;
        assert_eq!(attributed.label, "In room 3");
    }

    #[test]
    fn capture_mode_only_streams_the_selected_sources() {
        assert_eq!(active_channels_for_mode("both"), [true, true]);
        assert_eq!(active_channels_for_mode("system"), [true, false]);
        assert_eq!(active_channels_for_mode("mic"), [false, true]);
    }

    #[tokio::test]
    async fn a_provider_error_terminates_the_pipeline_without_waiting_for_audio_eof() {
        let pending_audio = std::future::pending::<Result<(), String>>();
        let provider_failure = async { Err("realtime provider rejected the stream".to_string()) };
        let pending_room = std::future::pending::<Result<(), String>>();

        let result = tokio::time::timeout(
            Duration::from_millis(100),
            run_realtime_pipeline(pending_audio, provider_failure, pending_room),
        )
        .await
        .expect("provider failures must not wait for stdin to close");

        assert_eq!(result.unwrap_err(), "realtime provider rejected the stream");
    }
}
