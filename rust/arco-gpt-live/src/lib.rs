use arco_core::gpt_live::{bound_delegation_result, build_speakable_events};
use arco_core::meetings::parse_meeting;
use arco_core::models::MeetingDetail;
use bytes::Bytes;
use opus_pure::{Application, MAX_PACKET_BYTES, OpusDecoder, OpusEncoder};
use rtc::interceptor::Registry;
use rtc::media::Sample;
use rtc::media_stream::MediaStreamTrack;
use rtc::peer_connection::configuration::RTCConfigurationBuilder;
use rtc::peer_connection::configuration::interceptor_registry::register_default_interceptors;
use rtc::peer_connection::configuration::media_engine::{MIME_TYPE_OPUS, MediaEngine};
use rtc::peer_connection::sdp::RTCSessionDescription;
use rtc::rtp_transceiver::rtp_sender::{
    RTCRtpCodec, RTCRtpCodecParameters, RTCRtpCodingParameters, RTCRtpEncodingParameters,
    RtpCodecKind,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Duration;
use std::{
    collections::{BTreeMap, VecDeque},
    fmt,
    future::Future,
    path::PathBuf,
    str::FromStr,
};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderName, HeaderValue, Request};
use url::Url;
use webrtc::media_stream::track_local::TrackLocal;
use webrtc::media_stream::track_local::static_sample::TrackLocalStaticSample;
use webrtc::media_stream::track_remote::{TrackRemote, TrackRemoteEvent};
use webrtc::peer_connection::{
    PeerConnection, PeerConnectionBuilder, PeerConnectionEventHandler, RTCIceGatheringState,
    RTCPeerConnectionState,
};

pub const OPUS_SAMPLE_RATE: u32 = 48_000;
pub const OPUS_CHANNELS: usize = 2;
pub const OPUS_FRAME_DURATION_MS: u64 = 20;
pub const OPUS_FRAME_SAMPLES_PER_CHANNEL: usize = 960;
pub const GPT_LIVE_INPUT_SAMPLE_RATE: u32 = 16_000;
pub const GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL: usize = 320;
const GPT_LIVE_INPUT_FRAME_BYTES: usize =
    GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL * OPUS_CHANNELS * size_of::<i16>();
const MAX_RECORDER_READ_BYTES: usize = 1024 * 1024;
const OPUS_MAX_PACKET_BYTES: usize = 1_275;
const OPUS_MAX_DECODE_SAMPLES_PER_CHANNEL: usize = 5_760;
const INBOUND_OPUS_REORDER_DEPTH: u16 = 4;
const INBOUND_OPUS_REORDER_WAIT: Duration =
    Duration::from_millis(INBOUND_OPUS_REORDER_DEPTH as u64 * OPUS_FRAME_DURATION_MS);
const RTP_SEQUENCE_HALF_RANGE: u16 = 0x8000;
const REMOTE_PLAYBACK_PREBUFFER_FRAMES: usize = 3;
const SPEECH_PROBE_RMS_DBFS: f64 = -50.0;
const SPEECH_PROBE_DURATION_MS: usize = 100;

pub const LIVE_BETA_ACK: &str = "gpt-live-beta-private-api";
const EMPTY_MEETING_TRANSCRIPT_TEXT: &str = "The current meeting transcript is still empty. Tell the user that Arco does not have enough meeting content yet.";
const MEETING_CONSULT_FAILURE_TEXT: &str =
    "The meeting agent task failed. Tell the user it did not complete and offer to try again.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InboundOpusPacket {
    ssrc: u32,
    sequence_number: u16,
    payload: Vec<u8>,
}

impl InboundOpusPacket {
    pub fn new(ssrc: u32, sequence_number: u16, payload: Vec<u8>) -> Self {
        Self {
            ssrc,
            sequence_number,
            payload,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InboundOpusAction {
    Decode(Vec<u8>),
    Conceal20ms,
}

pub struct InboundOpusReorderBuffer {
    active_ssrc: Option<u32>,
    next_sequence: Option<u16>,
    pending: BTreeMap<u16, Vec<u8>>,
    depth: u16,
}

impl InboundOpusReorderBuffer {
    pub fn gpt_live() -> Self {
        Self {
            active_ssrc: None,
            next_sequence: None,
            pending: BTreeMap::new(),
            depth: INBOUND_OPUS_REORDER_DEPTH,
        }
    }

    pub fn push(&mut self, packet: InboundOpusPacket) -> Result<Vec<InboundOpusAction>, String> {
        match self.active_ssrc {
            Some(ssrc) if ssrc != packet.ssrc => {
                return Err("GPT-Live WebRTC audio source changed unexpectedly".into());
            }
            None => self.active_ssrc = Some(packet.ssrc),
            _ => {}
        }

        let Some(expected) = self.next_sequence else {
            self.next_sequence = Some(packet.sequence_number.wrapping_add(1));
            return Ok(vec![InboundOpusAction::Decode(packet.payload)]);
        };
        let distance = packet.sequence_number.wrapping_sub(expected);
        if distance >= RTP_SEQUENCE_HALF_RANGE {
            return Ok(Vec::new());
        }
        if distance == 0 {
            self.next_sequence = Some(expected.wrapping_add(1));
            let mut ready = vec![InboundOpusAction::Decode(packet.payload)];
            self.drain_contiguous(&mut ready);
            return Ok(ready);
        }
        if self.pending.contains_key(&packet.sequence_number) {
            return Ok(Vec::new());
        }
        self.pending.insert(packet.sequence_number, packet.payload);
        Ok(self.flush_ready(false))
    }

    pub fn flush_timeout(&mut self) -> Vec<InboundOpusAction> {
        self.flush_ready(true)
    }

    fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    fn flush_ready(&mut self, force: bool) -> Vec<InboundOpusAction> {
        let Some(expected) = self.next_sequence else {
            return Vec::new();
        };
        let mut ordered = self
            .pending
            .keys()
            .copied()
            .map(|sequence| (sequence, sequence.wrapping_sub(expected)))
            .filter(|(_, distance)| *distance < RTP_SEQUENCE_HALF_RANGE)
            .collect::<Vec<_>>();
        ordered.sort_by_key(|(_, distance)| *distance);
        let (Some((nearest_sequence, nearest_distance)), Some((_, farthest_distance))) =
            (ordered.first().copied(), ordered.last().copied())
        else {
            return Vec::new();
        };
        if !force && farthest_distance < self.depth {
            return Vec::new();
        }

        let conceal = nearest_distance.min(self.depth);
        let mut ready = Vec::with_capacity(conceal as usize + self.pending.len());
        for _ in 0..conceal {
            self.next_sequence = self.next_sequence.map(|value| value.wrapping_add(1));
            ready.push(InboundOpusAction::Conceal20ms);
        }
        if nearest_distance > self.depth {
            self.next_sequence = Some(nearest_sequence);
        }
        self.drain_contiguous(&mut ready);
        ready
    }

    fn drain_contiguous(&mut self, ready: &mut Vec<InboundOpusAction>) {
        while let Some(sequence) = self.next_sequence {
            let Some(payload) = self.pending.remove(&sequence) else {
                break;
            };
            self.next_sequence = Some(sequence.wrapping_add(1));
            ready.push(InboundOpusAction::Decode(payload));
        }
    }
}

pub struct RemotePlaybackPrebuffer {
    samples: Vec<i16>,
    target_samples: usize,
}

impl RemotePlaybackPrebuffer {
    pub fn gpt_live() -> Self {
        Self {
            samples: Vec::with_capacity(
                OPUS_FRAME_SAMPLES_PER_CHANNEL * OPUS_CHANNELS * REMOTE_PLAYBACK_PREBUFFER_FRAMES,
            ),
            target_samples: OPUS_FRAME_SAMPLES_PER_CHANNEL
                * OPUS_CHANNELS
                * REMOTE_PLAYBACK_PREBUFFER_FRAMES,
        }
    }

    pub fn push(&mut self, pcm: &[i16]) -> Option<Vec<i16>> {
        self.samples.extend_from_slice(pcm);
        (self.samples.len() >= self.target_samples).then(|| std::mem::take(&mut self.samples))
    }

    pub fn reset(&mut self) {
        self.samples.clear();
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GptLiveSessionOptions {
    pub recorder: PathBuf,
    pub mode: String,
    pub transcript: PathBuf,
    pub provider: String,
}

impl GptLiveSessionOptions {
    pub fn parse(arguments: &[String]) -> Result<Self, String> {
        if arguments.len() != 10 || !arguments.len().is_multiple_of(2) {
            return Err("GPT-Live session arguments are incomplete".into());
        }
        let mut acknowledgement = None;
        let mut recorder = None;
        let mut mode = None;
        let mut transcript = None;
        let mut provider = None;
        for pair in arguments.chunks_exact(2) {
            let destination = match pair[0].as_str() {
                "--ack" => &mut acknowledgement,
                "--recorder" => &mut recorder,
                "--mode" => &mut mode,
                "--transcript" => &mut transcript,
                "--provider" => &mut provider,
                _ => return Err("GPT-Live session received an unsupported argument".into()),
            };
            if destination.replace(pair[1].clone()).is_some() {
                return Err("GPT-Live session received a duplicate argument".into());
            }
        }
        require_beta_ack(acknowledgement.as_deref())?;
        let recorder =
            PathBuf::from(recorder.ok_or_else(|| "GPT-Live recorder path is missing".to_string())?);
        if !recorder.is_absolute() {
            return Err("GPT-Live recorder path must be absolute".into());
        }
        let mode = mode.ok_or_else(|| "GPT-Live audio mode is missing".to_string())?;
        if !matches!(mode.as_str(), "both" | "system" | "mic") {
            return Err("GPT-Live audio mode must be both, system, or mic".into());
        }
        let transcript = PathBuf::from(
            transcript.ok_or_else(|| "GPT-Live transcript path is missing".to_string())?,
        );
        if !transcript.is_absolute() {
            return Err("GPT-Live transcript path must be absolute".into());
        }
        let provider = provider.ok_or_else(|| "GPT-Live agent provider is missing".to_string())?;
        if !matches!(provider.as_str(), "codex" | "claude") {
            return Err("GPT-Live agent provider must be codex or claude".into());
        }
        Ok(Self {
            recorder,
            mode,
            transcript,
            provider,
        })
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GptLiveRuntimeCommand {
    Session(GptLiveSessionOptions),
    AuthStatus,
    Login,
    Logout,
}

pub fn parse_runtime_command(arguments: &[String]) -> Result<GptLiveRuntimeCommand, String> {
    match arguments.first().map(String::as_str) {
        Some("session") => {
            GptLiveSessionOptions::parse(&arguments[1..]).map(GptLiveRuntimeCommand::Session)
        }
        Some(command @ ("auth-status" | "login" | "logout"))
            if arguments.len() == 3 && arguments[1] == "--ack" =>
        {
            require_beta_ack(Some(&arguments[2]))?;
            Ok(match command {
                "auth-status" => GptLiveRuntimeCommand::AuthStatus,
                "login" => GptLiveRuntimeCommand::Login,
                "logout" => GptLiveRuntimeCommand::Logout,
                _ => unreachable!(),
            })
        }
        _ => Err(format!(
            "usage: arco-gpt-live <session|auth-status|login|logout> --ack {LIVE_BETA_ACK} ..."
        )),
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GptLiveMeetingContext {
    transcript: PathBuf,
    provider: String,
}

impl GptLiveMeetingContext {
    pub fn new(transcript: PathBuf, provider: &str) -> Result<Self, String> {
        if !transcript.is_absolute() {
            return Err("GPT-Live transcript path must be absolute".into());
        }
        if !matches!(provider, "codex" | "claude") {
            return Err("GPT-Live agent provider must be codex or claude".into());
        }
        Ok(Self {
            transcript,
            provider: provider.into(),
        })
    }

    pub fn answer_with<F>(
        &self,
        delegation_id: &str,
        prompt: &str,
        consult: F,
    ) -> Result<Vec<serde_json::Value>, String>
    where
        F: FnOnce(&str, &str, &MeetingDetail) -> Result<String, String>,
    {
        let mut meeting = match parse_meeting(&self.transcript, "local", Some(&self.transcript)) {
            Ok(meeting) => meeting,
            Err(_) => return build_speakable_events(delegation_id, MEETING_CONSULT_FAILURE_TEXT),
        };
        let answer = if meeting.lines.is_empty() {
            EMPTY_MEETING_TRANSCRIPT_TEXT.into()
        } else {
            // `parse_meeting` merges the active `.live.json` sidecar into
            // `lines`, while `raw_markdown` intentionally remains durable-only.
            // AgentRunner consumes `raw_markdown`, so render the merged current
            // view here to avoid answering from a stale pre-finalization file.
            meeting.raw_markdown = meeting
                .lines
                .iter()
                .map(|line| format!("**[{}] {}:** {}", line.timestamp, line.speaker, line.text))
                .collect::<Vec<_>>()
                .join("\n\n");
            match consult(&self.provider, prompt, &meeting) {
                Ok(answer) => bound_delegation_result(&answer),
                Err(_) => MEETING_CONSULT_FAILURE_TEXT.into(),
            }
        };
        build_speakable_events(delegation_id, &answer)
    }
}

#[derive(Default)]
pub struct RecorderPcmFramer {
    pending: Vec<u8>,
}

impl RecorderPcmFramer {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<i16>>, String> {
        if bytes.len() > MAX_RECORDER_READ_BYTES {
            return Err("GPT-Live recorder read is too large".into());
        }
        self.pending.extend_from_slice(bytes);
        let complete_bytes =
            self.pending.len() / GPT_LIVE_INPUT_FRAME_BYTES * GPT_LIVE_INPUT_FRAME_BYTES;
        let mut frames = Vec::with_capacity(complete_bytes / GPT_LIVE_INPUT_FRAME_BYTES);
        for frame in self.pending[..complete_bytes].chunks_exact(GPT_LIVE_INPUT_FRAME_BYTES) {
            frames.push(
                frame
                    .chunks_exact(2)
                    .map(|sample| i16::from_le_bytes([sample[0], sample[1]]))
                    .collect(),
            );
        }
        self.pending.drain(..complete_bytes);
        Ok(frames)
    }

    pub fn finish(self) -> Result<(), String> {
        if self.pending.is_empty() {
            Ok(())
        } else {
            Err("GPT-Live recorder ended with an incomplete PCM frame".into())
        }
    }
}

pub struct SpeechEnergyGate {
    consecutive_loud_frames: usize,
    required_loud_frames: usize,
    normalized_rms_threshold: f64,
}

pub struct TranscriptMarkerGate {
    marker: String,
    observed: String,
    matched: bool,
}

impl TranscriptMarkerGate {
    pub fn new(marker: &str) -> Result<Self, String> {
        let marker = marker.trim().to_ascii_lowercase();
        if marker.is_empty() || marker.len() > 256 {
            return Err("GPT-Live transcript marker is invalid".into());
        }
        Ok(Self {
            marker,
            observed: String::new(),
            matched: false,
        })
    }

    pub fn observe(&mut self, text: &str) -> bool {
        if self.matched {
            return true;
        }
        self.observed.push_str(&text.to_ascii_lowercase());
        while self.observed.len() > 2_048 {
            let first_character_bytes = self
                .observed
                .chars()
                .next()
                .map(char::len_utf8)
                .unwrap_or(0);
            if first_character_bytes == 0 {
                break;
            }
            self.observed.drain(..first_character_bytes);
        }
        self.matched = self.observed.contains(&self.marker);
        self.matched
    }
}

impl SpeechEnergyGate {
    pub fn gpt_live_smoke() -> Self {
        Self {
            consecutive_loud_frames: 0,
            required_loud_frames: OPUS_SAMPLE_RATE as usize * SPEECH_PROBE_DURATION_MS / 1_000,
            normalized_rms_threshold: 10_f64.powf(SPEECH_PROBE_RMS_DBFS / 20.0),
        }
    }

    pub fn observe_stereo(&mut self, pcm: &[i16]) -> Result<bool, String> {
        if !pcm.len().is_multiple_of(OPUS_CHANNELS) {
            return Err("GPT-Live speech probe requires complete stereo PCM frames".into());
        }
        if pcm.is_empty() {
            self.consecutive_loud_frames = 0;
            return Ok(false);
        }
        let sum_squares = pcm
            .iter()
            .map(|sample| {
                let normalized = f64::from(*sample) / 32_768.0;
                normalized * normalized
            })
            .sum::<f64>();
        let rms = (sum_squares / pcm.len() as f64).sqrt();
        if rms < self.normalized_rms_threshold {
            self.consecutive_loud_frames = 0;
            return Ok(false);
        }
        self.consecutive_loud_frames = self
            .consecutive_loud_frames
            .saturating_add(pcm.len() / OPUS_CHANNELS);
        Ok(self.consecutive_loud_frames >= self.required_loud_frames)
    }
}

pub async fn finish_live_handshake<Sideband, Media>(
    sideband: Sideband,
    media: Media,
) -> Result<(), String>
where
    Sideband: Future<Output = Result<(), String>>,
    Media: Future<Output = Result<(), String>>,
{
    tokio::try_join!(sideband, media)?;
    Ok(())
}

#[derive(Clone, PartialEq, Eq)]
pub struct HttpsProxyConfig {
    host: String,
    port: u16,
    username: Option<String>,
    password: Option<String>,
}

impl HttpsProxyConfig {
    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn has_credentials(&self) -> bool {
        self.username.is_some()
    }

    pub fn credentials(&self) -> Option<(&str, &str)> {
        self.username
            .as_deref()
            .zip(self.password.as_deref().or(Some("")))
    }
}

impl fmt::Debug for HttpsProxyConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HttpsProxyConfig")
            .field("host", &self.host)
            .field("port", &self.port)
            .field("credentials", &self.username.as_ref().map(|_| "[REDACTED]"))
            .finish()
    }
}

pub fn resolve_https_proxy(target_host: &str) -> Result<Option<HttpsProxyConfig>, String> {
    let variables = [
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
        "ALL_PROXY",
        "all_proxy",
        "NO_PROXY",
        "no_proxy",
    ]
    .into_iter()
    .filter_map(|key| std::env::var(key).ok().map(|value| (key.into(), value)))
    .collect::<BTreeMap<_, _>>();
    resolve_https_proxy_from(&variables, target_host)
}

pub fn resolve_https_proxy_from(
    variables: &BTreeMap<String, String>,
    target_host: &str,
) -> Result<Option<HttpsProxyConfig>, String> {
    if target_host.is_empty()
        || target_host.len() > 253
        || !target_host
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
    {
        return Err("GPT-Live sideband target host is invalid".into());
    }
    if ["NO_PROXY", "no_proxy"]
        .iter()
        .find_map(|key| variables.get(*key))
        .is_some_and(|value| no_proxy_matches(value, target_host))
    {
        return Ok(None);
    }
    let Some(proxy_url) = [
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
        "ALL_PROXY",
        "all_proxy",
    ]
    .iter()
    .find_map(|key| {
        variables
            .get(*key)
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
    }) else {
        return Ok(None);
    };
    let url = Url::parse(proxy_url)
        .map_err(|_| "GPT-Live proxy URL is invalid; expected an HTTP CONNECT proxy".to_string())?;
    if url.scheme() != "http"
        || url.host_str().is_none()
        || url.query().is_some()
        || url.fragment().is_some()
        || !matches!(url.path(), "" | "/")
    {
        return Err("GPT-Live proxy must be an http:// URL without a path or query".into());
    }
    if url.password().is_some() && url.username().is_empty() {
        return Err("GPT-Live proxy credentials are invalid".into());
    }
    Ok(Some(HttpsProxyConfig {
        host: url.host_str().expect("checked above").into(),
        port: url.port().unwrap_or(80),
        username: (!url.username().is_empty()).then(|| url.username().to_string()),
        password: url.password().map(str::to_string),
    }))
}

fn no_proxy_matches(value: &str, target_host: &str) -> bool {
    value.split(',').any(|entry| {
        let mut pattern = entry.trim().to_ascii_lowercase();
        if pattern == "*" {
            return true;
        }
        if let Some((host, port)) = pattern.rsplit_once(':')
            && port.bytes().all(|byte| byte.is_ascii_digit())
        {
            pattern = host.to_string();
        }
        let pattern = pattern.strip_prefix("*.").unwrap_or(&pattern);
        let pattern = pattern.strip_prefix('.').unwrap_or(pattern);
        !pattern.is_empty()
            && (target_host.eq_ignore_ascii_case(pattern)
                || target_host
                    .to_ascii_lowercase()
                    .ends_with(&format!(".{pattern}")))
    })
}

pub fn require_beta_ack(value: Option<&str>) -> Result<(), String> {
    if value == Some(LIVE_BETA_ACK) {
        Ok(())
    } else {
        Err(format!(
            "live GPT-Live probing requires --ack {LIVE_BETA_ACK}"
        ))
    }
}

pub fn callback_url_from_http_request(request: &[u8]) -> Result<String, String> {
    if request.len() > 16 * 1024 {
        return Err("OpenAI OAuth callback request is too large".into());
    }
    let request = std::str::from_utf8(request)
        .map_err(|_| "OpenAI OAuth callback request is not valid UTF-8".to_string())?;
    let request_line = request
        .split("\r\n")
        .next()
        .ok_or_else(|| "OpenAI OAuth callback request is empty".to_string())?;
    let fields = request_line.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 3
        || fields[0] != "GET"
        || !matches!(fields[2], "HTTP/1.0" | "HTTP/1.1")
        || !fields[1].starts_with("/auth/callback")
        || fields[1].contains('#')
    {
        return Err("OpenAI OAuth callback HTTP request is invalid".into());
    }
    let callback_url = format!("http://localhost:1455{}", fields[1]);
    let parsed = Url::parse(&callback_url)
        .map_err(|_| "OpenAI OAuth callback target is invalid".to_string())?;
    if parsed.path() != "/auth/callback" {
        return Err("OpenAI OAuth callback target is invalid".into());
    }
    Ok(callback_url)
}

pub fn build_sideband_request(
    sideband_url: &str,
    headers: &BTreeMap<String, String>,
) -> Result<Request<()>, String> {
    let url = Url::parse(sideband_url).map_err(|_| "GPT-Live sideband URL is invalid")?;
    if url.scheme() != "wss"
        || url.host_str() != Some("api.openai.com")
        || url.port().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err("GPT-Live sideband URL has an unexpected target".into());
    }
    let call_id = url
        .path()
        .strip_prefix("/v1/live/")
        .filter(|value| is_safe_call_id(value))
        .ok_or_else(|| "GPT-Live sideband URL has an invalid call id".to_string())?;
    if call_id.contains('/') {
        return Err("GPT-Live sideband URL has an invalid call id".into());
    }

    let required_headers = [
        "Authorization",
        "OpenAI-Alpha",
        "chatgpt-account-id",
        "session-id",
        "thread-id",
        "x-session-id",
        "User-Agent",
        "originator",
        "version",
    ];
    if headers.len() != required_headers.len()
        || required_headers
            .iter()
            .any(|name| !headers.contains_key(*name))
    {
        return Err("GPT-Live sideband authentication headers are incomplete".into());
    }
    let mut request = sideband_url
        .into_client_request()
        .map_err(|_| "GPT-Live sideband request could not be created".to_string())?;
    for (name, value) in headers {
        let name = HeaderName::from_str(name)
            .map_err(|_| "GPT-Live sideband header name is invalid".to_string())?;
        let value = HeaderValue::from_str(value)
            .map_err(|_| "GPT-Live sideband header value is invalid".to_string())?;
        request.headers_mut().insert(name, value);
    }
    Ok(request)
}

fn is_safe_call_id(value: &str) -> bool {
    let rtc = value.strip_prefix("rtc_").is_some_and(|suffix| {
        !suffix.is_empty()
            && suffix.len() <= 124
            && suffix
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
    });
    let uuid_parts = value.split('-').map(str::len).collect::<Vec<_>>();
    let uuid = uuid_parts == [8, 4, 4, 4, 12]
        && value
            .chars()
            .all(|character| character == '-' || character.is_ascii_hexdigit());
    rtc || uuid
}

pub struct OpusDuplex {
    encoder: OpusEncoder,
    decoder: OpusDecoder,
}

impl OpusDuplex {
    pub fn new() -> Result<Self, String> {
        let encoder =
            OpusEncoder::new(OPUS_SAMPLE_RATE as i32, OPUS_CHANNELS, Application::Voip)
                .map_err(|error| format!("could not create GPT-Live Opus encoder: {error}"))?;
        let decoder = OpusDecoder::new(OPUS_SAMPLE_RATE as i32, OPUS_CHANNELS)
            .map_err(|error| format!("could not create GPT-Live Opus decoder: {error}"))?;
        Ok(Self { encoder, decoder })
    }

    pub fn encode_20ms_stereo(&mut self, pcm: &[i16]) -> Result<Vec<u8>, String> {
        if pcm.len() != OPUS_FRAME_SAMPLES_PER_CHANNEL * OPUS_CHANNELS {
            return Err(
                "GPT-Live Opus input must contain exactly 20 ms of 48 kHz stereo PCM".into(),
            );
        }
        let mut packet = vec![0_u8; OPUS_MAX_PACKET_BYTES];
        let encoded = self
            .encoder
            .encode_s16(pcm, OPUS_FRAME_SAMPLES_PER_CHANNEL, &mut packet)
            .map_err(|error| format!("could not encode GPT-Live Opus audio: {error}"))?;
        packet.truncate(encoded);
        Ok(packet)
    }

    pub fn decode_stereo(&mut self, packet: &[u8]) -> Result<Vec<i16>, String> {
        if packet.len() > MAX_PACKET_BYTES {
            return Err("GPT-Live Opus packet is too large".into());
        }
        let mut pcm = vec![0_i16; OPUS_MAX_DECODE_SAMPLES_PER_CHANNEL * OPUS_CHANNELS];
        let samples_per_channel = self
            .decoder
            .decode_s16(packet, OPUS_MAX_DECODE_SAMPLES_PER_CHANNEL, &mut pcm)
            .map_err(|error| format!("could not decode GPT-Live Opus audio: {error}"))?;
        pcm.truncate(samples_per_channel * OPUS_CHANNELS);
        Ok(pcm)
    }

    pub fn conceal_20ms_stereo(&mut self) -> Result<Vec<i16>, String> {
        let mut pcm = vec![0_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * OPUS_CHANNELS];
        let samples_per_channel = self
            .decoder
            .decode_s16(&[], OPUS_FRAME_SAMPLES_PER_CHANNEL, &mut pcm)
            .map_err(|error| format!("could not conceal lost GPT-Live Opus audio: {error}"))?;
        pcm.truncate(samples_per_channel * OPUS_CHANNELS);
        Ok(pcm)
    }
}

struct AudioPeerHandler {
    gather_complete: tokio::sync::mpsc::Sender<()>,
    connection_state: tokio::sync::watch::Sender<RTCPeerConnectionState>,
    inbound_opus: tokio::sync::mpsc::Sender<InboundOpusPacket>,
    inbound_track_attached: AtomicBool,
}

impl AudioPeerHandler {
    async fn attach_inbound_track(&self, track: Arc<dyn TrackRemote>) {
        if track.kind().await != RtpCodecKind::Audio
            || self
                .inbound_track_attached
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_err()
        {
            return;
        }
        let inbound_opus = self.inbound_opus.clone();
        tokio::spawn(async move {
            while let Some(event) = track.poll().await {
                match event {
                    TrackRemoteEvent::OnRtpPacket(packet) => {
                        let inbound = InboundOpusPacket::new(
                            packet.header.ssrc,
                            packet.header.sequence_number,
                            packet.payload.to_vec(),
                        );
                        if inbound_opus.send(inbound).await.is_err() {
                            break;
                        }
                    }
                    TrackRemoteEvent::OnEnded | TrackRemoteEvent::OnError => break,
                    _ => {}
                }
            }
        });
    }
}

struct InboundOpusPipeline {
    packets: tokio::sync::mpsc::Receiver<InboundOpusPacket>,
    reorder: InboundOpusReorderBuffer,
    ready: VecDeque<InboundOpusAction>,
}

#[async_trait::async_trait]
impl PeerConnectionEventHandler for AudioPeerHandler {
    async fn on_ice_gathering_state_change(&self, state: RTCIceGatheringState) {
        if state == RTCIceGatheringState::Complete {
            let _ = self.gather_complete.try_send(());
        }
    }

    async fn on_connection_state_change(&self, state: RTCPeerConnectionState) {
        self.connection_state.send_replace(state);
    }

    async fn on_track(&self, track: Arc<dyn TrackRemote>) {
        self.attach_inbound_track(track).await;
    }
}

pub struct GptLiveWebRtcPeer {
    peer: Arc<dyn PeerConnection>,
    track: Arc<TrackLocalStaticSample>,
    ssrc: u32,
    codec: tokio::sync::Mutex<OpusDuplex>,
    recorder_encoder: tokio::sync::Mutex<OpusEncoder>,
    gather_complete: tokio::sync::Mutex<tokio::sync::mpsc::Receiver<()>>,
    connection_state: tokio::sync::watch::Receiver<RTCPeerConnectionState>,
    inbound_opus: tokio::sync::Mutex<InboundOpusPipeline>,
    event_handler: Arc<AudioPeerHandler>,
    local_description_started: AtomicBool,
}

impl GptLiveWebRtcPeer {
    pub async fn new() -> Result<Self, String> {
        let mut media_engine = MediaEngine::default();
        let opus_codec = opus_rtp_codec();
        media_engine
            .register_codec(
                RTCRtpCodecParameters {
                    rtp_codec: opus_codec.clone(),
                    payload_type: 111,
                },
                RtpCodecKind::Audio,
            )
            .map_err(|error| format!("could not register GPT-Live Opus codec: {error}"))?;
        let interceptor_registry =
            register_default_interceptors(Registry::new(), &mut media_engine)
                .map_err(|error| format!("could not register GPT-Live RTP handlers: {error}"))?;
        let (gather_tx, gather_rx) = tokio::sync::mpsc::channel(1);
        let (state_tx, state_rx) = tokio::sync::watch::channel(RTCPeerConnectionState::New);
        let (inbound_tx, inbound_rx) = tokio::sync::mpsc::channel(128);
        let handler = Arc::new(AudioPeerHandler {
            gather_complete: gather_tx,
            connection_state: state_tx,
            inbound_opus: inbound_tx,
            inbound_track_attached: AtomicBool::new(false),
        });
        let configuration = RTCConfigurationBuilder::new().build();
        let peer = PeerConnectionBuilder::new()
            .with_configuration(configuration)
            .with_media_engine(media_engine)
            .with_interceptor_registry(interceptor_registry)
            .with_handler(handler.clone() as Arc<dyn PeerConnectionEventHandler>)
            .with_udp_addrs(vec!["0.0.0.0:0".to_string()])
            .build()
            .await
            .map_err(|error| format!("could not create GPT-Live WebRTC peer: {error}"))?;
        let peer: Arc<dyn PeerConnection> = Arc::new(peer);
        let ssrc = next_ssrc();
        let track = Arc::new(
            TrackLocalStaticSample::new(MediaStreamTrack::new(
                "arco-gpt-live-stream".into(),
                "arco-gpt-live-audio".into(),
                "Arco GPT-Live Beta".into(),
                RtpCodecKind::Audio,
                vec![RTCRtpEncodingParameters {
                    rtp_coding_parameters: RTCRtpCodingParameters {
                        ssrc: Some(ssrc),
                        ..Default::default()
                    },
                    codec: opus_codec,
                    ..Default::default()
                }],
            ))
            .map_err(|error| format!("could not create GPT-Live audio track: {error}"))?,
        );
        peer.add_track(Arc::clone(&track) as Arc<dyn TrackLocal>)
            .await
            .map_err(|error| format!("could not add GPT-Live audio track: {error}"))?;

        Ok(Self {
            peer,
            track,
            ssrc,
            codec: tokio::sync::Mutex::new(OpusDuplex::new()?),
            recorder_encoder: tokio::sync::Mutex::new(
                OpusEncoder::new(
                    GPT_LIVE_INPUT_SAMPLE_RATE as i32,
                    OPUS_CHANNELS,
                    Application::Voip,
                )
                .map_err(|error| {
                    format!("could not create GPT-Live recorder Opus encoder: {error}")
                })?,
            ),
            gather_complete: tokio::sync::Mutex::new(gather_rx),
            connection_state: state_rx,
            inbound_opus: tokio::sync::Mutex::new(InboundOpusPipeline {
                packets: inbound_rx,
                reorder: InboundOpusReorderBuffer::gpt_live(),
                ready: VecDeque::new(),
            }),
            event_handler: handler,
            local_description_started: AtomicBool::new(false),
        })
    }

    pub async fn create_offer(&self, timeout: Duration) -> Result<String, String> {
        self.begin_local_description()?;
        let offer = self
            .peer
            .create_offer(None)
            .await
            .map_err(|error| format!("could not create GPT-Live SDP offer: {error}"))?;
        self.peer
            .set_local_description(offer)
            .await
            .map_err(|error| format!("could not set GPT-Live SDP offer: {error}"))?;
        self.wait_for_gathering(timeout).await?;
        self.local_sdp("offer").await
    }

    pub async fn answer_offer(&self, offer_sdp: &str, timeout: Duration) -> Result<String, String> {
        self.begin_local_description()?;
        let offer = RTCSessionDescription::offer(offer_sdp.to_string())
            .map_err(|error| format!("could not parse GPT-Live SDP offer: {error}"))?;
        self.peer
            .set_remote_description(offer)
            .await
            .map_err(|error| format!("could not apply GPT-Live SDP offer: {error}"))?;
        let answer = self
            .peer
            .create_answer(None)
            .await
            .map_err(|error| format!("could not create GPT-Live SDP answer: {error}"))?;
        self.peer
            .set_local_description(answer)
            .await
            .map_err(|error| format!("could not set GPT-Live SDP answer: {error}"))?;
        self.wait_for_gathering(timeout).await?;
        self.local_sdp("answer").await
    }

    pub async fn apply_answer(&self, answer_sdp: &str) -> Result<(), String> {
        let answer = RTCSessionDescription::answer(answer_sdp.to_string())
            .map_err(|error| format!("could not parse GPT-Live SDP answer: {error}"))?;
        self.peer
            .set_remote_description(answer)
            .await
            .map_err(|error| format!("could not apply GPT-Live SDP answer: {error}"))?;
        // GPT-Live answers may omit SSRC declarations, so the generic on_track event
        // is not guaranteed to identify the receiver. Attach its stable default track
        // immediately after negotiation, matching browser/WebRTC-library behavior.
        for receiver in self.peer.get_receivers().await {
            let track = Arc::clone(receiver.track());
            if track.kind().await == RtpCodecKind::Audio {
                self.event_handler.attach_inbound_track(track).await;
                break;
            }
        }
        Ok(())
    }

    pub async fn wait_connected(&self, timeout: Duration) -> Result<(), String> {
        let mut states = self.connection_state.clone();
        let wait = async move {
            loop {
                match *states.borrow_and_update() {
                    RTCPeerConnectionState::Connected => return Ok(()),
                    RTCPeerConnectionState::Failed | RTCPeerConnectionState::Closed => {
                        return Err("GPT-Live WebRTC connection failed".to_string());
                    }
                    _ => {}
                }
                states
                    .changed()
                    .await
                    .map_err(|_| "GPT-Live WebRTC connection state ended".to_string())?;
            }
        };
        tokio::time::timeout(timeout, wait)
            .await
            .map_err(|_| "GPT-Live WebRTC connection timed out".to_string())?
    }

    pub async fn send_20ms_stereo(&self, pcm: &[i16]) -> Result<(), String> {
        let packet = self.codec.lock().await.encode_20ms_stereo(pcm)?;
        self.write_opus_packet(packet).await
    }

    /// The native Arco recorder already emits 16 kHz stereo PCM. Opus accepts
    /// that sample rate directly while RTP continues using Opus's fixed 48 kHz
    /// clock, so no custom resampler is needed in the Beta worker.
    pub async fn send_20ms_recorder_stereo(&self, pcm: &[i16]) -> Result<(), String> {
        if pcm.len() != GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL * OPUS_CHANNELS {
            return Err(
                "GPT-Live recorder input must contain exactly 20 ms of 16 kHz stereo PCM".into(),
            );
        }
        let mut packet = vec![0_u8; OPUS_MAX_PACKET_BYTES];
        let encoded = self
            .recorder_encoder
            .lock()
            .await
            .encode_s16(pcm, GPT_LIVE_INPUT_FRAME_SAMPLES_PER_CHANNEL, &mut packet)
            .map_err(|error| format!("could not encode GPT-Live recorder audio: {error}"))?;
        packet.truncate(encoded);
        self.write_opus_packet(packet).await
    }

    async fn write_opus_packet(&self, packet: Vec<u8>) -> Result<(), String> {
        self.track
            .write_sample(
                self.ssrc,
                111,
                &Sample {
                    data: Bytes::from(packet),
                    duration: Duration::from_millis(OPUS_FRAME_DURATION_MS),
                    ..Default::default()
                },
                &[],
            )
            .await
            .map_err(|error| format!("could not send GPT-Live Opus audio: {error}"))
    }

    pub async fn receive_decoded_stereo(&self, timeout: Duration) -> Result<Vec<i16>, String> {
        let deadline = tokio::time::Instant::now() + timeout;
        let action = {
            let mut inbound = self.inbound_opus.lock().await;
            loop {
                if let Some(action) = inbound.ready.pop_front() {
                    break action;
                }
                let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
                if remaining.is_zero() {
                    return Err("GPT-Live audio receive timed out".into());
                }
                let waiting_for_reorder = inbound.reorder.has_pending();
                let wait = if waiting_for_reorder {
                    remaining.min(INBOUND_OPUS_REORDER_WAIT)
                } else {
                    remaining
                };
                match tokio::time::timeout(wait, inbound.packets.recv()).await {
                    Ok(Some(packet)) => {
                        let ready = inbound.reorder.push(packet)?;
                        inbound.ready.extend(ready);
                    }
                    Ok(None) => return Err("GPT-Live audio track ended".into()),
                    Err(_) if waiting_for_reorder && wait == INBOUND_OPUS_REORDER_WAIT => {
                        let ready = inbound.reorder.flush_timeout();
                        inbound.ready.extend(ready);
                    }
                    Err(_) => return Err("GPT-Live audio receive timed out".into()),
                }
            }
        };
        let mut codec = self.codec.lock().await;
        match action {
            InboundOpusAction::Decode(packet) => codec.decode_stereo(&packet),
            InboundOpusAction::Conceal20ms => codec.conceal_20ms_stereo(),
        }
    }

    pub async fn close(&self) -> Result<(), String> {
        self.peer
            .close()
            .await
            .map_err(|error| format!("could not close GPT-Live WebRTC peer: {error}"))
    }

    fn begin_local_description(&self) -> Result<(), String> {
        self.local_description_started
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map(|_| ())
            .map_err(|_| "GPT-Live WebRTC local description was already created".into())
    }

    async fn wait_for_gathering(&self, timeout: Duration) -> Result<(), String> {
        tokio::time::timeout(timeout, self.gather_complete.lock().await.recv())
            .await
            .map_err(|_| "GPT-Live ICE gathering timed out".to_string())?
            .ok_or_else(|| "GPT-Live ICE gathering ended unexpectedly".to_string())?;
        Ok(())
    }

    async fn local_sdp(&self, kind: &str) -> Result<String, String> {
        self.peer
            .local_description()
            .await
            .map(|description| description.sdp)
            .filter(|sdp| !sdp.trim().is_empty())
            .ok_or_else(|| format!("GPT-Live WebRTC {kind} is empty"))
    }
}

fn opus_rtp_codec() -> RTCRtpCodec {
    RTCRtpCodec {
        mime_type: MIME_TYPE_OPUS.to_string(),
        clock_rate: OPUS_SAMPLE_RATE,
        channels: OPUS_CHANNELS as u16,
        sdp_fmtp_line: "minptime=10;useinbandfec=1".into(),
        rtcp_feedback: vec![],
    }
}

fn next_ssrc() -> u32 {
    static NEXT: AtomicU32 = AtomicU32::new(0x4152_434f);
    NEXT.fetch_add(1, Ordering::Relaxed).max(1)
}

pub async fn create_audio_offer() -> Result<String, String> {
    let peer = GptLiveWebRtcPeer::new().await?;
    let offer = peer.create_offer(Duration::from_secs(5)).await;
    let close = peer.close().await;
    match (offer, close) {
        (Ok(offer), Ok(())) => Ok(offer),
        (Err(error), _) | (Ok(_), Err(error)) => Err(error),
    }
}
