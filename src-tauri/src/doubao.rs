use chrono::{Local, TimeZone};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue};
use tokio_tungstenite::tungstenite::Message;

const ENDPOINT: &str = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel";
const RESOURCE_ID: &str = "volc.bigasr.sauc.duration";
const SAMPLE_RATE: usize = 16_000;
const STEREO_FRAME_BYTES: usize = 4;
const READ_CHUNK_BYTES: usize = 6_400;
const SPEAKER_TIMELINE_WAIT: Duration = Duration::from_millis(1_500);

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
    sequence: i32,
    enable_speaker_info: bool,
) -> Result<Vec<u8>, String> {
    let language = match language {
        "zh-CN" => Some("zh-CN"),
        "en-US" => Some("en-US"),
        "auto" => None,
        other => return Err(format!("unsupported Doubao recognition language: {other}")),
    };
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
            "result_type": "full"
        }
    });
    if let Some(language) = language {
        request["request"]["language"] = Value::String(language.into());
    }
    let payload = gzip(
        &serde_json::to_vec(&request)
            .map_err(|error| format!("could not encode Doubao request: {error}"))?,
    )?;
    let mut packet = vec![0x11, 0x11, 0x11, 0x01];
    packet.extend_from_slice(&sequence.to_be_bytes());
    packet.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    packet.extend_from_slice(&payload);
    Ok(packet)
}

pub fn encode_audio_request(
    sequence: i32,
    audio: &[u8],
    final_packet: bool,
) -> Result<Vec<u8>, String> {
    if sequence <= 0 {
        return Err("Doubao audio request sequence must be positive.".into());
    }
    let payload = gzip(audio)?;
    let mut packet = vec![0x11, if final_packet { 0x23 } else { 0x21 }, 0x00, 0x01];
    packet.extend_from_slice(&(if final_packet { -sequence } else { sequence }).to_be_bytes());
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
            let start = utterance
                .get("start_time")
                .or_else(|| utterance.get("startTime"))?
                .as_f64()?
                / 1_000.0;
            let end = utterance
                .get("end_time")
                .or_else(|| utterance.get("endTime"))?
                .as_f64()?
                / 1_000.0;
            let provider_speaker = utterance
                .get("additions")
                .and_then(|value| value.get("speaker"))
                .and_then(|value| value.as_i64().or_else(|| value.as_str()?.parse().ok()))
                .unwrap_or(1);
            let speaker = provider_speaker.saturating_sub(1).max(0);
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
) -> Result<
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
    String,
> {
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
            encode_full_client_request(request_id, language, 1, enable_speaker_info)?.into(),
        ))
        .await
        .map_err(|error| format!("Doubao initial request failed: {error}"))?;
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

pub async fn verify_credentials(app_id: &str, access_token: &str) -> Result<(), String> {
    let request_id = uuid::Uuid::new_v4().to_string();
    let mut socket = tokio::time::timeout(
        Duration::from_secs(8),
        connect_socket(app_id, access_token, &request_id, "zh-CN", false),
    )
    .await
    .map_err(|_| "Doubao credential verification timed out.".to_string())??;
    let response = tokio::time::timeout(Duration::from_secs(8), socket.next())
        .await
        .map_err(|_| {
            "Doubao did not acknowledge the credential verification request.".to_string()
        })?;
    match receive_protocol_message(response).await? {
        Some(ServerMessage::Error { code, message }) => Err(format!(
            "Doubao rejected these credentials ({code}): {message}"
        )),
        Some(ServerMessage::Result { .. } | ServerMessage::Acknowledgement { .. }) => {
            let _ = socket.close(None).await;
            Ok(())
        }
        None => Err("Doubao returned an unexpected verification response.".into()),
    }
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

async fn run_channel(
    app_id: &str,
    access_token: &str,
    language: &str,
    channel: usize,
    enabled: bool,
    mut receiver: mpsc::Receiver<Vec<u8>>,
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
    let request_id = uuid::Uuid::new_v4().to_string();
    let mut socket =
        connect_socket(app_id, access_token, &request_id, language, role != "asr").await?;
    let mut sequence = 2i32;
    let mut pending: Option<Vec<u8>> = None;
    let mut emitted = HashSet::<(i64, i64, String)>::new();
    let mut ready_announced = false;
    let mut closing = false;
    let deadline = tokio::time::sleep(Duration::from_secs(365 * 24 * 60 * 60));
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            audio = receiver.recv(), if !closing => {
                match audio {
                    Some(audio) => {
                        if let Some(previous) = pending.replace(audio) {
                            socket.send(Message::Binary(encode_audio_request(sequence, &previous, false)?.into()))
                                .await
                                .map_err(|error| format!("Doubao audio send failed: {error}"))?;
                            sequence += 1;
                        }
                    }
                    None => {
                        let final_audio = pending.take().unwrap_or_default();
                        socket.send(Message::Binary(encode_audio_request(sequence, &final_audio, true)?.into()))
                            .await
                            .map_err(|error| format!("Doubao final audio send failed: {error}"))?;
                        closing = true;
                        deadline.as_mut().reset(tokio::time::Instant::now() + Duration::from_secs(5));
                    }
                }
            }
            message = socket.next() => {
                let Some(message) = receive_protocol_message(message).await? else { continue; };
                if !ready_announced {
                    ready_announced = true;
                    ready.send(channel).await.map_err(|_| "Doubao readiness coordinator stopped.".to_string())?;
                }
                match message {
                    ServerMessage::Error { code, message } => {
                        return Err(format!("Doubao transcription failed ({code}): {message}"));
                    }
                    ServerMessage::Acknowledgement { .. } => {}
                    ServerMessage::Result { is_final, payload, .. } => {
                        for segment in segments_from_payload(&payload, channel, is_final) {
                            let key = ((segment.start * 1000.0) as i64, (segment.end * 1000.0) as i64, segment.text.clone());
                            if emitted.insert(key) {
                                if let Some(store) = timeline_store.as_ref() {
                                    store.lock().await.update(
                                        channel,
                                        segment.end,
                                        vec![crate::speaker_timeline::SpeakerInterval {
                                            speaker: segment.speaker,
                                            start: segment.start,
                                            end: segment.end,
                                        }],
                                        Vec::new(),
                                    )?;
                                }
                                if role != "diarization" {
                                    let segment = if role == "combined" {
                                        segment
                                    } else {
                                        attribute_segment(segment, timeline.as_deref()).await
                                    };
                                    writer.lock().await.append(&segment)?;
                                }
                            }
                        }
                        if closing && is_final {
                            let _ = socket.close(None).await;
                            return Ok(());
                        }
                    }
                }
            }
            _ = &mut deadline, if closing => {
                let _ = socket.close(None).await;
                return Ok(());
            }
        }
    }
}

async fn pump_stdin(senders: [mpsc::Sender<Vec<u8>>; 2]) -> Result<(), String> {
    let mut input = tokio::io::stdin();
    let mut carry = Vec::new();
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
            let (remote, room) = split_stereo_pcm(&chunk)?;
            for (sender, audio) in senders.iter().zip([remote, room]) {
                sender
                    .send(audio)
                    .await
                    .map_err(|_| "Doubao audio worker stopped.".to_string())?;
            }
        }
    }
    let aligned = carry.len() / STEREO_FRAME_BYTES * STEREO_FRAME_BYTES;
    if aligned > 0 {
        let (remote, room) = split_stereo_pcm(&carry[..aligned])?;
        for (sender, audio) in senders.iter().zip([remote, room]) {
            sender
                .send(audio)
                .await
                .map_err(|_| "Doubao audio worker stopped.".to_string())?;
        }
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
    let writer = Arc::new(Mutex::new(TranscriptWriter::new(
        transcript_path.to_path_buf(),
        session_started_at,
    )?));
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
    let (remote_sender, remote_receiver) = mpsc::channel(600);
    let (room_sender, room_receiver) = mpsc::channel(600);
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
        writer,
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
    tokio::try_join!(pump, remote, room, readiness)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_headers_use_the_official_doubao_streaming_contract() {
        let headers = credential_headers("app-id", "access-token", "request-id").unwrap();
        assert_eq!(headers.get("X-Api-App-Key").unwrap(), "app-id");
        assert_eq!(headers.get("X-Api-Access-Key").unwrap(), "access-token");
        assert_eq!(headers.get("X-Api-Resource-Id").unwrap(), RESOURCE_ID);
        assert_eq!(headers.get("X-Api-Request-Id").unwrap(), "request-id");
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
    fn first_request_is_gzip_json_with_positive_sequence() {
        let packet = encode_full_client_request("request-id", "zh-CN", 1, true).unwrap();
        assert_eq!(&packet[..4], &[0x11, 0x11, 0x11, 0x01]);
        assert_eq!(i32::from_be_bytes(packet[4..8].try_into().unwrap()), 1);
        let payload_size = u32::from_be_bytes(packet[8..12].try_into().unwrap()) as usize;
        assert_eq!(packet.len(), 12 + payload_size);
    }

    #[test]
    fn audio_requests_distinguish_streaming_and_final_sequences() {
        let streaming = encode_audio_request(2, &[1, 2, 3, 4], false).unwrap();
        let final_packet = encode_audio_request(3, &[5, 6, 7, 8], true).unwrap();
        assert_eq!(&streaming[..4], &[0x11, 0x21, 0x00, 0x01]);
        assert_eq!(i32::from_be_bytes(streaming[4..8].try_into().unwrap()), 2);
        assert_eq!(&final_packet[..4], &[0x11, 0x23, 0x00, 0x01]);
        assert_eq!(
            i32::from_be_bytes(final_packet[4..8].try_into().unwrap()),
            -3
        );
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
    fn full_request_explicitly_enables_doubao_speaker_separation() {
        let packet = encode_full_client_request("request-id", "zh-CN", 1, true).unwrap();
        let size = u32::from_be_bytes(packet[8..12].try_into().unwrap()) as usize;
        let payload = gunzip(&packet[12..12 + size]).unwrap();
        let request: Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(request["request"]["enable_speaker_info"], true);
        assert_eq!(request["request"]["show_utterances"], true);
    }
}
