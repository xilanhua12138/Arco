use crate::speaker_timeline::{
    wait_for_speaker, SpeakerInterval as TimelineInterval, SpeakerTimelineStore,
};
use chrono::{Local, TimeZone};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::{AsyncReadExt, Stdin};
use tokio::sync::mpsc;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;

const SAMPLE_RATE: usize = 16_000;
const FRAME_BYTES: usize = 4;
const READ_CHUNK_BYTES: usize = 6_400;
const DEFAULT_BUFFER_SECONDS: usize = 60;
const SPEAKER_TIMELINE_WAIT: Duration = Duration::from_millis(1_500);

#[derive(Clone, Debug, PartialEq)]
pub struct Segment {
    pub channel: usize,
    pub speaker: Option<i64>,
    pub label: String,
    pub text: String,
    pub start: f64,
    pub end: f64,
    pub connection_id: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TranscriberRole {
    Combined,
    Asr,
    Diarization,
}

impl TranscriberRole {
    fn from_environment() -> Result<Self, String> {
        match std::env::var("ARCO_TRANSCRIBER_ROLE")
            .unwrap_or_else(|_| "combined".into())
            .as_str()
        {
            "combined" => Ok(Self::Combined),
            "asr" => Ok(Self::Asr),
            "diarization" => Ok(Self::Diarization),
            value => Err(format!("unsupported Deepgram transcriber role: {value}")),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
struct TimelineUpdate {
    channel: usize,
    processed_until: f64,
    finalized: Vec<TimelineInterval>,
    tentative: Vec<TimelineInterval>,
}

#[derive(Clone, Debug)]
struct AudioChunk {
    data: Vec<u8>,
    start_frame: usize,
}

pub fn deepgram_url(model: &str, language: &str) -> String {
    deepgram_url_with_diarization(model, language, true)
}

pub fn deepgram_url_with_diarization(model: &str, language: &str, diarization: bool) -> String {
    let language = match language {
        "zh-CN" | "zh-Hans" => "zh-Hans",
        "en-US" => "en-US",
        "auto" => "multi",
        value if !value.trim().is_empty() => value,
        _ => "zh-Hans",
    };
    let mut url = format!(
        "wss://api.deepgram.com/v1/listen?model={}&language={}&encoding=linear16&sample_rate=16000&channels=2&multichannel=true&punctuate=true&smart_format=true&endpointing=300",
        urlencoding::encode(if model.trim().is_empty() { "nova-3" } else { model }),
        urlencoding::encode(language),
    );
    if diarization {
        url.push_str("&diarize_model=latest");
    }
    url
}

pub fn deepgram_payload_error(payload: &Value) -> Option<String> {
    let payload_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    let status = payload
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_ascii_lowercase();
    let raw_error = payload
        .get("error")
        .filter(|value| !value.is_null() && **value != Value::Bool(false));
    let failed_metadata =
        payload_type == "metadata" && matches!(status.as_str(), "error" | "failed" | "invalid");
    if payload_type != "error" && raw_error.is_none() && !failed_metadata {
        return None;
    }
    raw_error
        .and_then(|value| {
            value.as_str().map(str::to_string).or_else(|| {
                value
                    .get("message")
                    .and_then(Value::as_str)
                    .map(str::to_string)
                    .or_else(|| {
                        value
                            .get("description")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    })
            })
        })
        .or_else(|| {
            payload
                .get("message")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| {
            payload
                .get("description")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| {
            payload
                .get("code")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .or_else(|| Some("Deepgram returned an unknown streaming error".into()))
}

pub fn segments_from_result(payload: &Value) -> Vec<Segment> {
    if payload.get("type").and_then(Value::as_str) != Some("Results")
        || payload.get("is_final").and_then(Value::as_bool) != Some(true)
    {
        return Vec::new();
    }
    let channel = response_channel(payload);
    let alternative = payload
        .pointer("/channel/alternatives/0")
        .cloned()
        .unwrap_or_else(|| json!({}));
    let payload_start = number(payload.get("start"), 0.0);
    let payload_end = payload_start + number(payload.get("duration"), 0.0);
    let words = alternative
        .get("words")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut segments = Vec::new();
    let mut current_speaker: Option<i64> = None;
    let mut current_words: Vec<String> = Vec::new();
    let mut current_start = payload_start;
    let mut current_end = payload_end;
    let mut has_group = false;

    let flush = |segments: &mut Vec<Segment>,
                 words: &mut Vec<String>,
                 speaker: Option<i64>,
                 start: f64,
                 end: f64| {
        let text = join_words(words);
        if !text.is_empty() {
            segments.push(Segment {
                channel,
                speaker,
                label: participant_label(channel, speaker),
                text,
                start,
                end: end.max(start),
                connection_id: None,
            });
        }
        words.clear();
    };

    for word in words {
        let speaker = word.get("speaker").and_then(Value::as_i64);
        let word_start = number(word.get("start"), payload_start);
        let word_end = number(word.get("end"), word_start);
        if has_group && speaker != current_speaker {
            flush(
                &mut segments,
                &mut current_words,
                current_speaker,
                current_start,
                current_end,
            );
            has_group = false;
        }
        if !has_group {
            current_speaker = speaker;
            current_start = word_start;
            current_end = word_end;
            has_group = true;
        } else {
            current_end = current_end.max(word_end);
        }
        if let Some(token) = word
            .get("punctuated_word")
            .or_else(|| word.get("word"))
            .and_then(Value::as_str)
        {
            let token = token.trim();
            if !token.is_empty() {
                current_words.push(token.to_string());
            }
        }
    }
    flush(
        &mut segments,
        &mut current_words,
        current_speaker,
        current_start,
        current_end,
    );
    if !segments.is_empty() {
        return segments;
    }
    let text = alternative
        .get("transcript")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if text.is_empty() {
        return Vec::new();
    }
    vec![Segment {
        channel,
        speaker: None,
        label: participant_label(channel, None),
        text: text.into(),
        start: payload_start,
        end: payload_end.max(payload_start),
        connection_id: None,
    }]
}

fn timeline_update_from_result(payload: &Value, origin: f64) -> Option<TimelineUpdate> {
    if payload.get("type").and_then(Value::as_str) != Some("Results")
        || payload.get("is_final").and_then(Value::as_bool) != Some(true)
    {
        return None;
    }
    let channel = response_channel(payload);
    let payload_start = number(payload.get("start"), 0.0) + origin;
    let payload_end = payload_start + number(payload.get("duration"), 0.0);
    let words = payload
        .pointer("/channel/alternatives/0/words")
        .and_then(Value::as_array)?;
    let mut finalized: Vec<TimelineInterval> = Vec::new();
    for word in words {
        let Some(speaker) = word.get("speaker").and_then(Value::as_i64) else {
            continue;
        };
        let start = number(word.get("start"), payload_start - origin) + origin;
        let end = number(word.get("end"), start - origin) + origin;
        if end <= start {
            continue;
        }
        if let Some(previous) = finalized.last_mut() {
            if previous.speaker == speaker && start <= previous.end + 0.02 {
                previous.end = previous.end.max(end);
                continue;
            }
        }
        finalized.push(TimelineInterval {
            speaker,
            start,
            end,
        });
    }
    Some(TimelineUpdate {
        channel,
        processed_until: payload_end,
        finalized,
        tentative: Vec::new(),
    })
}

fn response_channel(payload: &Value) -> usize {
    let value = payload.get("channel_index").unwrap_or(&Value::Null);
    value
        .as_u64()
        .or_else(|| {
            value
                .as_array()
                .and_then(|values| values.first())
                .and_then(Value::as_u64)
        })
        .unwrap_or(0) as usize
}

fn number(value: Option<&Value>, fallback: f64) -> f64 {
    value.and_then(Value::as_f64).unwrap_or(fallback)
}

fn participant_label(channel: usize, speaker: Option<i64>) -> String {
    let prefix = if channel == 0 { "Remote" } else { "In room" };
    speaker
        .map(|value| format!("{prefix} {}", value + 1))
        .unwrap_or_else(|| prefix.into())
}

fn is_cjk(character: char) -> bool {
    matches!(character as u32, 0x3400..=0x9fff | 0x3040..=0x30ff | 0xac00..=0xd7af)
}

fn join_words(tokens: &[String]) -> String {
    let mut result = String::new();
    for token in tokens.iter().filter(|token| !token.is_empty()) {
        let first = token.chars().next().unwrap_or_default();
        let last = result.chars().last();
        let punctuation = ",.;:!?%)]}，。！？、；：）】".contains(first);
        let open = last.map(|value| "([{（【".contains(value)).unwrap_or(false);
        if result.is_empty()
            || last.map(is_cjk).unwrap_or(false)
            || is_cjk(first)
            || punctuation
            || open
        {
            result.push_str(token);
        } else {
            result.push(' ');
            result.push_str(token);
        }
    }
    result.trim().to_string()
}

#[derive(Default)]
struct SpeakerRegistry {
    labels: HashMap<(u64, usize, Option<i64>), usize>,
    next: [usize; 2],
}

impl SpeakerRegistry {
    fn speaker_id(&mut self, connection_id: u64, channel: usize, speaker: Option<i64>) -> usize {
        let channel = channel.min(1);
        let key = (connection_id, channel, speaker);
        *self.labels.entry(key).or_insert_with(|| {
            let number = self.next[channel];
            self.next[channel] += 1;
            number
        })
    }

    fn relabel(&mut self, segments: Vec<Segment>, connection_id: u64) -> Vec<Segment> {
        segments
            .into_iter()
            .map(|mut segment| {
                let number = self.speaker_id(connection_id, segment.channel, segment.speaker);
                segment.label = format!(
                    "{} {}",
                    if segment.channel == 0 {
                        "Remote"
                    } else {
                        "In room"
                    },
                    number + 1,
                );
                segment.speaker = Some(number as i64);
                segment.connection_id = Some(connection_id);
                segment
            })
            .collect()
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
        let seconds = self.session_started_at + segment.start;
        let timestamp = Local
            .timestamp_opt(seconds as i64, 0)
            .single()
            .unwrap_or_else(Local::now)
            .format("%H:%M:%S");
        let mut file = OpenOptions::new()
            .append(true)
            .open(&self.path)
            .map_err(|error| {
                format!("could not open transcript {}: {error}", self.path.display())
            })?;
        writeln!(
            file,
            "**[{timestamp}] {}:** {}\n",
            segment.label, segment.text
        )
        .and_then(|_| {
            writeln!(
                file,
                "<!-- arco channel={} speaker={} stream={} start={:.3} end={:.3} -->\n",
                segment.channel,
                segment
                    .speaker
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "unknown".into()),
                segment
                    .connection_id
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "unknown".into()),
                segment.start,
                segment.end,
            )
        })
        .map_err(|error| format!("could not append live transcript: {error}"))?;
        file.flush()
            .map_err(|error| format!("could not flush live transcript: {error}"))
    }
}

async fn pump_stdin(mut input: Stdin, sender: mpsc::Sender<AudioChunk>) {
    let mut next_frame = 0usize;
    let mut carry = Vec::new();
    loop {
        let mut buffer = vec![0u8; READ_CHUNK_BYTES];
        let Ok(read) = input.read(&mut buffer).await else {
            break;
        };
        if read == 0 {
            break;
        }
        carry.extend_from_slice(&buffer[..read]);
        let aligned = carry.len() / FRAME_BYTES * FRAME_BYTES;
        if aligned == 0 {
            continue;
        }
        let tail = carry.split_off(aligned);
        let data = std::mem::replace(&mut carry, tail);
        let frames = data.len() / FRAME_BYTES;
        if sender
            .send(AudioChunk {
                data,
                start_frame: next_frame,
            })
            .await
            .is_err()
        {
            break;
        }
        next_frame += frames;
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
    let mut file = fs::File::create(&temporary).map_err(|error| error.to_string())?;
    file.write_all(b"deepgram-ready\n")
        .and_then(|_| file.sync_all())
        .map_err(|error| error.to_string())?;
    fs::rename(&temporary, &path).map_err(|error| error.to_string())
}

#[allow(clippy::too_many_arguments)]
async fn stream_connection(
    api_key: &str,
    url: &str,
    receiver: &mut mpsc::Receiver<AudioChunk>,
    writer: Option<&TranscriptWriter>,
    timeline_store: &mut Option<SpeakerTimelineStore>,
    external_timeline: Option<&Path>,
    role: TranscriberRole,
    speakers: &mut SpeakerRegistry,
    connection_id: u64,
) -> Result<bool, String> {
    let mut request = url
        .into_client_request()
        .map_err(|error| format!("invalid Deepgram request: {error}"))?;
    request.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Token {api_key}"))
            .map_err(|_| "invalid Deepgram credential header".to_string())?,
    );
    let (socket, _) = connect_async(request)
        .await
        .map_err(|error| format!("Deepgram connection failed: {error}"))?;
    signal_ready()?;
    let (mut sink, mut stream) = socket.split();
    let mut keepalive = tokio::time::interval(Duration::from_secs(5));
    let mut connection_origin: Option<f64> = None;
    let mut closing = false;
    let close_deadline = tokio::time::sleep(Duration::from_secs(8));
    tokio::pin!(close_deadline);
    loop {
        tokio::select! {
            _ = keepalive.tick(), if !closing => {
                sink.send(Message::Text(r#"{"type":"KeepAlive"}"#.into())).await.map_err(|error| format!("Deepgram keepalive failed: {error}"))?;
            }
            chunk = receiver.recv(), if !closing => {
                match chunk {
                    Some(chunk) => {
                        connection_origin.get_or_insert(chunk.start_frame as f64 / SAMPLE_RATE as f64);
                        sink.send(Message::Binary(chunk.data.into())).await.map_err(|error| format!("Deepgram audio send failed: {error}"))?;
                    }
                    None => {
                        closing = true;
                        sink.send(Message::Text(r#"{"type":"CloseStream"}"#.into())).await.map_err(|error| format!("Deepgram close failed: {error}"))?;
                    }
                }
            }
            message = stream.next() => {
                match message {
                    Some(Ok(Message::Text(text))) => {
                        let Ok(payload) = serde_json::from_str::<Value>(&text) else { continue };
                        if let Some(error) = deepgram_payload_error(&payload) {
                            return Err(format!("Deepgram rejected the streaming configuration: {error}"));
                        }
                        let origin = connection_origin.unwrap_or(0.0);
                        if role == TranscriberRole::Diarization {
                            if let Some(mut update) = timeline_update_from_result(&payload, origin) {
                                for interval in &mut update.finalized {
                                    interval.speaker = speakers.speaker_id(
                                        connection_id,
                                        update.channel,
                                        Some(interval.speaker),
                                    ) as i64;
                                }
                                if let Some(store) = timeline_store.as_mut() {
                                    store.update(
                                        update.channel,
                                        update.processed_until,
                                        update.finalized,
                                        update.tentative,
                                    )?;
                                }
                            }
                            continue;
                        }

                        let shifted: Vec<_> = segments_from_result(&payload).into_iter().map(|mut segment| {
                            segment.start += origin;
                            segment.end += origin;
                            segment
                        }).collect();
                        let attributed = if role == TranscriberRole::Combined {
                            speakers.relabel(shifted, connection_id)
                        } else {
                            let mut attributed = Vec::with_capacity(shifted.len());
                            for mut segment in shifted {
                                let speaker = if let Some(path) = external_timeline {
                                    wait_for_speaker(
                                        path,
                                        segment.channel,
                                        segment.start,
                                        segment.end,
                                        SPEAKER_TIMELINE_WAIT,
                                    )
                                    .await
                                    .unwrap_or(0)
                                } else {
                                    0
                                };
                                segment.speaker = Some(speaker);
                                segment.label = participant_label(segment.channel, Some(speaker));
                                segment.connection_id = None;
                                attributed.push(segment);
                            }
                            attributed
                        };
                        let writer = writer.ok_or_else(|| "Deepgram ASR has no transcript writer".to_string())?;
                        for segment in attributed {
                            writer.append(&segment)?;
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => return Ok(closing),
                    Some(Ok(_)) => {}
                    Some(Err(error)) => return Err(format!("Deepgram stream dropped: {error}")),
                }
            }
            _ = &mut close_deadline, if closing => return Ok(true),
        }
    }
}

pub async fn run_transcriber(transcript_path: &Path) -> Result<(), String> {
    let api_key = std::env::var("DEEPGRAM_API_KEY").unwrap_or_default();
    if api_key.trim().is_empty() {
        return Err("Deepgram is not configured in Arco Settings.".into());
    }
    let model = std::env::var("DEEPGRAM_MODEL").unwrap_or_else(|_| "nova-3".into());
    let language = std::env::var("DEEPGRAM_LANG").unwrap_or_else(|_| "zh-Hans".into());
    let role = TranscriberRole::from_environment()?;
    let timeline_path = std::env::var_os("ARCO_SPEAKER_TIMELINE_FILE").map(PathBuf::from);
    if role == TranscriberRole::Diarization && timeline_path.is_none() {
        return Err("Deepgram diarization requires ARCO_SPEAKER_TIMELINE_FILE".into());
    }
    let session_started_at = std::env::var("ARCO_SESSION_STARTED_AT_UNIX")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| chrono::Utc::now().timestamp_millis() as f64 / 1000.0);
    let writer = if role == TranscriberRole::Diarization {
        None
    } else {
        Some(TranscriptWriter::new(
            transcript_path.to_path_buf(),
            session_started_at,
        )?)
    };
    let mut timeline_store = timeline_path
        .as_ref()
        .filter(|_| role == TranscriberRole::Diarization)
        .map(|path| SpeakerTimelineStore::new(path.clone()));
    let buffer_seconds = std::env::var("ARCO_AUDIO_BUFFER_SECONDS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(DEFAULT_BUFFER_SECONDS)
        .clamp(1, 300);
    let capacity = buffer_seconds * 10;
    let (sender, mut receiver) = mpsc::channel(capacity);
    tokio::spawn(pump_stdin(tokio::io::stdin(), sender));
    let mut speakers = SpeakerRegistry::default();
    let mut connection_id = 0u64;
    let mut retry = 1u64;
    let url = deepgram_url_with_diarization(&model, &language, role != TranscriberRole::Asr);
    loop {
        connection_id += 1;
        match stream_connection(
            api_key.trim(),
            &url,
            &mut receiver,
            writer.as_ref(),
            &mut timeline_store,
            timeline_path
                .as_deref()
                .filter(|_| role == TranscriberRole::Asr),
            role,
            &mut speakers,
            connection_id,
        )
        .await
        {
            Ok(true) => return Ok(()),
            Ok(false) => {}
            Err(error)
                if error.contains("HTTP 401")
                    || error.contains("HTTP 403")
                    || error.contains("rejected the streaming configuration") =>
            {
                return Err(error)
            }
            Err(error) => eprintln!("[reconnect] {error}; retrying in {retry}s"),
        }
        tokio::time::sleep(Duration::from_secs(retry)).await;
        retry = (retry * 2).min(15);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(channel: usize, words: Value, transcript: &str, final_result: bool) -> Value {
        json!({
            "type": "Results", "is_final": final_result, "channel_index": [channel, 2],
            "start": 0.0, "duration": 1.5,
            "channel": {"alternatives": [{"transcript": transcript, "words": words}]}
        })
    }

    #[test]
    fn websocket_contract_is_stereo_multichannel_and_diarized() {
        let url = deepgram_url("nova-3", "zh-CN");
        for expected in [
            "channels=2",
            "multichannel=true",
            "diarize_model=latest",
            "endpointing=300",
            "smart_format=true",
        ] {
            assert!(url.contains(expected), "missing {expected} from {url}");
        }
        assert!(!url.contains("interim_results"));
    }

    #[test]
    fn final_results_split_every_speaker_boundary_on_both_channels() {
        let payload = result(
            1,
            json!([
                {"punctuated_word":"First", "speaker":0, "start":0.0, "end":0.2},
                {"punctuated_word":"person.", "speaker":0, "start":0.2, "end":0.5},
                {"punctuated_word":"Second", "speaker":2, "start":0.6, "end":0.9},
                {"punctuated_word":"person.", "speaker":2, "start":0.9, "end":1.1}
            ]),
            "First person. Second person.",
            true,
        );
        let segments = segments_from_result(&payload);
        assert_eq!(
            segments
                .iter()
                .map(|segment| segment.label.as_str())
                .collect::<Vec<_>>(),
            vec!["In room 1", "In room 3"]
        );
        assert_eq!(
            segments
                .iter()
                .map(|segment| segment.text.as_str())
                .collect::<Vec<_>>(),
            vec!["First person.", "Second person."]
        );
        assert!(!segments.iter().any(|segment| segment.label == "You"));
    }

    #[test]
    fn independent_asr_can_disable_deepgram_diarization_while_diarizer_keeps_it_streaming() {
        let asr_url = deepgram_url_with_diarization("nova-3", "zh-CN", false);
        let diarization_url = deepgram_url_with_diarization("nova-3", "zh-CN", true);
        let automatic_url = deepgram_url_with_diarization("nova-3", "auto", true);

        assert!(!asr_url.contains("diarize"));
        assert!(diarization_url.contains("diarize_model=latest"));
        assert!(diarization_url.contains("multichannel=true"));
        assert!(automatic_url.contains("language=multi"));
        assert!(!automatic_url.contains("language=auto"));
    }

    #[test]
    fn finalized_words_become_channel_local_streaming_timeline_intervals() {
        let payload = result(
            1,
            json!([
                {"punctuated_word":"First", "speaker":0, "start":0.0, "end":0.4},
                {"punctuated_word":"still first", "speaker":0, "start":0.4, "end":0.8},
                {"punctuated_word":"Second", "speaker":2, "start":0.9, "end":1.3}
            ]),
            "First still first Second",
            true,
        );

        let update = timeline_update_from_result(&payload, 4.0).unwrap();
        assert_eq!(update.channel, 1);
        assert_eq!(update.processed_until, 5.5);
        assert_eq!(
            update.finalized,
            vec![
                crate::speaker_timeline::SpeakerInterval {
                    speaker: 0,
                    start: 4.0,
                    end: 4.8
                },
                crate::speaker_timeline::SpeakerInterval {
                    speaker: 2,
                    start: 4.9,
                    end: 5.3
                },
            ]
        );
        assert!(update.tentative.is_empty());
    }

    #[test]
    fn non_final_results_and_success_metadata_are_ignored() {
        assert!(segments_from_result(&result(0, json!([]), "draft", false)).is_empty());
        assert_eq!(
            deepgram_payload_error(&json!({"type":"Metadata", "request_id":"ok"})),
            None
        );
        assert_eq!(
            deepgram_payload_error(&json!({"type":"Error", "message":"bad language"})),
            Some("bad language".into())
        );
    }

    #[test]
    fn reconnects_receive_new_anonymous_speaker_namespaces() {
        let base = segments_from_result(&result(
            0,
            json!([
                {"punctuated_word":"Hello.", "speaker":0, "start":0.5, "end":0.8}
            ]),
            "Hello.",
            true,
        ));
        let mut registry = SpeakerRegistry::default();
        let first = registry.relabel(base.clone(), 1).remove(0);
        let second = registry.relabel(base, 2).remove(0);
        assert_eq!(
            (first.label.as_str(), second.label.as_str()),
            ("Remote 1", "Remote 2")
        );
    }
}
