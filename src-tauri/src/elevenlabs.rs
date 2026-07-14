use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use chrono::{Local, TimeZone};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::future::Future;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, Stdin};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

const SAMPLE_RATE: usize = 16_000;
const STEREO_FRAME_BYTES: usize = 4;
const READ_CHUNK_BYTES: usize = 6_400;
const DEFAULT_BUFFER_SECONDS: usize = 60;
const REALTIME_MODEL: &str = "scribe_v2_realtime";
const REALTIME_ENDPOINT: &str = "wss://api.elevenlabs.io/v1/speech-to-text/realtime";

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub channel: usize,
    pub label: String,
    pub text: String,
    pub start: f64,
    pub end: f64,
}

#[derive(Clone, Debug)]
struct AudioChunk {
    data: Vec<u8>,
    start_frame: usize,
}

pub fn realtime_url(language: &str) -> String {
    let language = match language {
        "zh-CN" | "zh-Hans" | "zh" => Some("zh"),
        "en-US" | "en" => Some("en"),
        _ => None,
    };
    let mut url = format!(
        "{REALTIME_ENDPOINT}?model_id={REALTIME_MODEL}&audio_format=pcm_16000&include_timestamps=true&commit_strategy=vad&vad_silence_threshold_secs=0.5"
    );
    if let Some(language) = language {
        url.push_str("&language_code=");
        url.push_str(language);
    }
    url
}

pub fn payload_error(payload: &Value) -> Option<String> {
    let message_type = payload
        .get("message_type")
        .or_else(|| payload.get("type"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    if message_type != "error" && payload.get("error").is_none() {
        return None;
    }
    payload
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
        .or_else(|| Some("ElevenLabs returned an unknown transcription error".into()))
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
        label: source_label(channel),
        text: text.into(),
        start,
        end: end.max(start),
    }]
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
                "<!-- arco channel={} speaker=0 stream=elevenlabs-realtime start={:.3} end={:.3} -->\n",
                segment.channel, segment.start, segment.end,
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

async fn pump_stdin(
    mut input: Stdin,
    senders: [mpsc::Sender<AudioChunk>; 2],
) -> Result<(), String> {
    let mut next_frame = 0usize;
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
        let aligned = carry.len() / STEREO_FRAME_BYTES * STEREO_FRAME_BYTES;
        if aligned == 0 {
            continue;
        }
        let tail = carry.split_off(aligned);
        let data = std::mem::replace(&mut carry, tail);
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
    channel: usize,
) -> Result<bool, String> {
    let (mut sink, mut stream) = socket.split();
    let mut connection_origin: Option<f64> = None;
    let mut closing = false;
    let close_deadline = tokio::time::sleep(Duration::from_secs(365 * 24 * 60 * 60));
    tokio::pin!(close_deadline);
    loop {
        tokio::select! {
            chunk = receiver.recv(), if !closing => {
                match chunk {
                    Some(chunk) => {
                        connection_origin.get_or_insert(chunk.start_frame as f64 / SAMPLE_RATE as f64);
                        let message = json!({
                            "message_type": "input_audio_chunk",
                            "audio_base_64": BASE64.encode(&chunk.data),
                            "sample_rate": SAMPLE_RATE,
                            "commit": false,
                        });
                        sink.send(Message::Text(message.to_string().into())).await
                            .map_err(|error| format!("ElevenLabs audio send failed: {error}"))?;
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
                        if let Some(error) = payload_error(&payload) {
                            return Err(format!("ElevenLabs rejected the streaming configuration: {error}"));
                        }
                        let origin = connection_origin.unwrap_or(0.0);
                        for mut segment in segments_from_realtime(&payload, channel) {
                            segment.start += origin;
                            segment.end += origin;
                            writer.lock().await.append(&segment)?;
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
    ready_channels: Arc<AtomicUsize>,
    expected_ready_channels: usize,
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
    let mut retry = 1u64;
    let mut first_connection = true;
    loop {
        match connect_socket(session.api_key, session.language).await {
            Ok(socket) => {
                if first_connection {
                    first_connection = false;
                    if session.ready_channels.fetch_add(1, Ordering::SeqCst) + 1
                        == session.expected_ready_channels
                    {
                        signal_ready()?;
                    }
                }
                match stream_connected_channel(socket, &mut receiver, &session.writer, channel)
                    .await
                {
                    Ok(true) => return Ok(()),
                    Ok(false) => {}
                    Err(error)
                        if error.contains("HTTP 401")
                            || error.contains("HTTP 403")
                            || error.contains("rejected the streaming configuration") =>
                    {
                        return Err(error);
                    }
                    Err(error) => {
                        eprintln!("[elevenlabs channel {channel}] {error}; retrying in {retry}s")
                    }
                }
            }
            Err(error) if error.contains("HTTP 401") || error.contains("HTTP 403") => {
                return Err(error);
            }
            Err(error) => eprintln!("[elevenlabs channel {channel}] {error}; retrying in {retry}s"),
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
            "language_code=zh",
        ] {
            assert!(url.contains(expected), "missing {expected} from {url}");
        }
        assert!(!url.contains("diar"));
        assert!(!url.contains("channels"));
        assert!(!realtime_url("auto").contains("language_code"));
    }

    #[test]
    fn stereo_recorder_frames_are_split_without_crossing_sources() {
        let (remote, room) = split_stereo_pcm(&[1, 2, 3, 4, 5, 6, 7, 8]);
        assert_eq!(remote, vec![1, 2, 5, 6]);
        assert_eq!(room, vec![3, 4, 7, 8]);
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
