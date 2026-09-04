use regex::Regex;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fmt;
use std::io::Read;
use std::sync::OnceLock;
use std::time::Duration;
use url::Url;
use uuid::Uuid;

pub const GPT_LIVE_MODEL: &str = "gpt-live-1-codex";
pub const GPT_LIVE_VOICE: &str = "spruce";
pub const GPT_LIVE_FEATURE_LABEL: &str = "Beta";
pub const CHATGPT_GPT_LIVE_CALL_URL: &str =
    "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas";

const SIDEBAND_URL_PREFIX: &str = "wss://api.openai.com/v1/live/";
const MAX_CONTEXT_ENTRIES: usize = 16;
const MAX_CONTEXT_ITEM_CHARS: usize = 800;
const MAX_CONTEXT_UTF8_BYTES: usize = 8_000;
const MAX_APPEND_UTF8_BYTES: usize = 500;
const MAX_DELEGATION_RESULT_CHARS: usize = 1_800;
const MAX_LOCATION_UTF8_BYTES: usize = 512;
const MAX_CALL_ID_CHARS: usize = 128;
const MAX_SIDEBAND_PAYLOAD_BYTES: usize = 16 * 1024 * 1024;
const MAX_SDP_BYTES: usize = 256 * 1024;
const MAX_ERROR_BODY_BYTES: usize = 64 * 1024;
const MAX_ERROR_DETAIL_CHARS: usize = 500;
const TRUNCATED_SUFFIX: &str = " [truncated]";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum GptLiveRole {
    User,
    Assistant,
}

impl GptLiveRole {
    fn from_wire(value: &str) -> Option<Self> {
        match value {
            "user" => Some(Self::User),
            "assistant" => Some(Self::Assistant),
            _ => None,
        }
    }

    fn content_type(self) -> &'static str {
        match self {
            Self::User => "input_text",
            Self::Assistant => "output_text",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InitialItem {
    pub role: GptLiveRole,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct GptLiveSession {
    model: String,
    instructions: String,
    audio: SessionAudio,
    delegation: SessionDelegation,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    initial_items: Vec<SessionInitialItem>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct SessionAudio {
    output: SessionAudioOutput,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct SessionAudioOutput {
    voice: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct SessionDelegation {
    #[serde(rename = "type")]
    kind: &'static str,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct SessionInitialItem {
    #[serde(rename = "type")]
    kind: &'static str,
    role: GptLiveRole,
    content: Vec<SessionInitialContent>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
struct SessionInitialContent {
    #[serde(rename = "type")]
    kind: &'static str,
    text: String,
}

impl GptLiveSession {
    pub fn new(
        instructions: &str,
        voice: Option<&str>,
        initial_items: Vec<InitialItem>,
    ) -> Result<Self, String> {
        let voice = voice.unwrap_or(GPT_LIVE_VOICE).trim();
        if voice != GPT_LIVE_VOICE {
            return Err("GPT-Live voice is not supported by this Arco build".into());
        }
        let initial_items = bound_initial_items(&initial_items)
            .into_iter()
            .map(|item| SessionInitialItem {
                kind: "message",
                role: item.role,
                content: vec![SessionInitialContent {
                    kind: item.role.content_type(),
                    text: item.text,
                }],
            })
            .collect();
        Ok(Self {
            model: GPT_LIVE_MODEL.into(),
            instructions: instructions.trim().into(),
            audio: SessionAudio {
                output: SessionAudioOutput {
                    voice: voice.into(),
                },
            },
            delegation: SessionDelegation { kind: "client" },
            initial_items,
        })
    }
}

pub fn bound_initial_items(items: &[InitialItem]) -> Vec<InitialItem> {
    let mut remaining_bytes = MAX_CONTEXT_UTF8_BYTES;
    let mut newest_first = Vec::new();
    for item in items.iter().rev().take(MAX_CONTEXT_ENTRIES) {
        if remaining_bytes == 0 {
            break;
        }
        let text = truncate_utf8(&item.text, MAX_CONTEXT_ITEM_CHARS, remaining_bytes);
        if text.is_empty() {
            continue;
        }
        remaining_bytes -= text.len();
        newest_first.push(InitialItem {
            role: item.role,
            text,
        });
    }
    newest_first.reverse();
    newest_first
}

fn truncate_utf8(text: &str, max_chars: usize, max_bytes: usize) -> String {
    let mut result = String::new();
    for character in text.chars().take(max_chars) {
        if result.len() + character.len_utf8() > max_bytes {
            break;
        }
        result.push(character);
    }
    result
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum GptLiveInboundEvent {
    Ignored { event_type: String },
    Unknown { event_type: String },
    SessionStarted { expires_at: Option<u64> },
    Audio { base64_data: String },
    TranscriptDelta { role: GptLiveRole, text: String },
    TranscriptDone { role: GptLiveRole, text: String },
    Delegation { id: String, prompt: String },
    Error { message: String, fatal_auth: bool },
}

pub fn parse_inbound_event(payload: &str) -> Option<GptLiveInboundEvent> {
    if payload.len() > MAX_SIDEBAND_PAYLOAD_BYTES {
        return None;
    }
    let decoded = serde_json::from_str::<Value>(payload).ok()?;
    let event_type = decoded.get("type")?.as_str()?.to_string();
    match event_type.as_str() {
        "session.started" => {
            let Some(session) = decoded.get("session").and_then(Value::as_object) else {
                return Some(ignored(event_type));
            };
            let expires_at = match session.get("expires_at") {
                Some(value) => match value.as_u64() {
                    Some(value) => Some(value),
                    None => return Some(ignored(event_type)),
                },
                None => None,
            };
            Some(GptLiveInboundEvent::SessionStarted { expires_at })
        }
        "input_transcript.added" | "output_transcript.added" => {
            let Some(text) = decoded
                .get("item")
                .and_then(|item| item.get("text"))
                .and_then(Value::as_str)
            else {
                return Some(ignored(event_type));
            };
            let role = if event_type == "input_transcript.added" {
                GptLiveRole::User
            } else {
                GptLiveRole::Assistant
            };
            Some(GptLiveInboundEvent::TranscriptDelta {
                role,
                text: text.into(),
            })
        }
        "turn.done" => {
            let Some(turn) = decoded.get("turn") else {
                return Some(ignored(event_type));
            };
            let Some(role) = turn
                .get("role")
                .and_then(Value::as_str)
                .and_then(GptLiveRole::from_wire)
            else {
                return Some(ignored(event_type));
            };
            let Some(text) = turn.get("transcript").and_then(Value::as_str) else {
                return Some(ignored(event_type));
            };
            Some(GptLiveInboundEvent::TranscriptDone {
                role,
                text: text.into(),
            })
        }
        "output_audio.delta" => match decoded.get("audio").and_then(Value::as_str) {
            Some(data) => Some(GptLiveInboundEvent::Audio {
                base64_data: data.into(),
            }),
            None => Some(ignored(event_type)),
        },
        "delegation.created" => {
            let Some(item) = decoded.get("item") else {
                return Some(ignored(event_type));
            };
            let valid_item = item.get("type").and_then(Value::as_str) == Some("delegation")
                && item.get("target").and_then(Value::as_str) == Some("client");
            let Some(id) = item
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
            else {
                return Some(ignored(event_type));
            };
            if !valid_item {
                return Some(ignored(event_type));
            }
            let prompt = item
                .get("content")
                .and_then(Value::as_array)
                .map(|parts| {
                    parts
                        .iter()
                        .filter(|part| {
                            part.get("type").and_then(Value::as_str) == Some("input_text")
                        })
                        .filter_map(|part| part.get("text").and_then(Value::as_str))
                        .collect::<String>()
                })
                .unwrap_or_default();
            Some(GptLiveInboundEvent::Delegation {
                id: id.into(),
                prompt,
            })
        }
        "error" => Some(GptLiveInboundEvent::Error {
            message: read_error_message(&decoded),
            fatal_auth: is_fatal_auth_error(&decoded),
        }),
        "session.updated" => Some(ignored(event_type)),
        _ => Some(GptLiveInboundEvent::Unknown { event_type }),
    }
}

fn ignored(event_type: String) -> GptLiveInboundEvent {
    GptLiveInboundEvent::Ignored { event_type }
}

fn read_error_message(decoded: &Value) -> String {
    decoded
        .get("message")
        .and_then(Value::as_str)
        .or_else(|| {
            decoded
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
        })
        .or_else(|| decoded.get("error").and_then(Value::as_str))
        .filter(|message| !message.trim().is_empty())
        .map(|message| message.trim().to_string())
        .unwrap_or_else(|| "GPT-Live sideband error".into())
}

fn is_fatal_auth_error(decoded: &Value) -> bool {
    let error = decoded.get("error");
    let status = decoded
        .get("status")
        .or_else(|| error.and_then(|value| value.get("status")));
    if status.and_then(Value::as_u64) == Some(401) || status.and_then(Value::as_str) == Some("401")
    {
        return true;
    }
    let code = decoded
        .get("code")
        .or_else(|| error.and_then(|value| value.get("code")))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(
        code.as_str(),
        "authentication_error" | "invalid_api_key" | "invalid_token" | "token_expired"
    )
}

pub fn bound_delegation_result(text: &str) -> String {
    if text.chars().count() <= MAX_DELEGATION_RESULT_CHARS {
        return text.into();
    }
    let content_chars = MAX_DELEGATION_RESULT_CHARS - TRUNCATED_SUFFIX.chars().count();
    let mut bounded = text.chars().take(content_chars).collect::<String>();
    let trimmed_len = bounded.trim_end().len();
    bounded.truncate(trimmed_len);
    bounded.push_str(TRUNCATED_SUFFIX);
    bounded
}

pub fn build_speakable_events(delegation_id: &str, text: &str) -> Result<Vec<Value>, String> {
    if !is_safe_identifier(delegation_id) {
        return Err("GPT-Live delegation id is invalid".into());
    }
    Ok(chunk_utf8(text, MAX_APPEND_UTF8_BYTES)
        .into_iter()
        .map(|chunk| {
            json!({
                "type": "delegation.context.append",
                "delegation_item_id": delegation_id,
                "channel": "speakable",
                "content": [{ "type": "input_text", "text": chunk }]
            })
        })
        .collect())
}

fn chunk_utf8(text: &str, max_bytes: usize) -> Vec<String> {
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut chunks = Vec::new();
    let mut current = String::new();
    for character in text.chars() {
        if !current.is_empty() && current.len() + character.len_utf8() > max_bytes {
            chunks.push(current);
            current = String::new();
        }
        current.push(character);
    }
    if !current.is_empty() {
        chunks.push(current);
    }
    chunks
}

pub fn extract_call_id(
    location: Option<&str>,
    openai_session_id: Option<&str>,
) -> Result<String, String> {
    if let Some(location) = location {
        if location.len() > MAX_LOCATION_UTF8_BYTES {
            return Err("GPT-Live call response Location is too large".into());
        }
        let base = Url::parse(CHATGPT_GPT_LIVE_CALL_URL)
            .map_err(|_| "GPT-Live call URL is invalid".to_string())?;
        let url = base
            .join(location)
            .map_err(|_| "GPT-Live call response returned an invalid Location".to_string())?;
        if url.scheme() != "https"
            || !matches!(url.host_str(), Some("chatgpt.com" | "api.openai.com"))
        {
            return Err("GPT-Live call response Location has an unexpected target".into());
        }
        if let Some(call_id) = url
            .path_segments()
            .into_iter()
            .flatten()
            .find(|value| is_call_id(value))
        {
            return Ok(call_id.into());
        }
    }
    if let Some(call_id) = openai_session_id
        .map(str::trim)
        .filter(|value| is_call_id(value))
    {
        return Ok(call_id.into());
    }
    Err("GPT-Live call response has no valid call id".into())
}

pub fn build_sideband_url(call_id: &str) -> Result<String, String> {
    if !is_call_id(call_id) {
        return Err("GPT-Live call id is invalid".into());
    }
    Ok(format!("{SIDEBAND_URL_PREFIX}{call_id}"))
}

fn is_call_id(value: &str) -> bool {
    if value.len() > MAX_CALL_ID_CHARS {
        return false;
    }
    let rtc = value
        .strip_prefix("rtc_")
        .is_some_and(|suffix| !suffix.is_empty() && is_safe_identifier(suffix));
    rtc || is_uuid(value)
}

fn is_uuid(value: &str) -> bool {
    let parts = value.split('-').map(str::len).collect::<Vec<_>>();
    parts == [8, 4, 4, 4, 12] && value.chars().all(|ch| ch == '-' || ch.is_ascii_hexdigit())
}

fn is_safe_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_CALL_ID_CHARS
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

#[derive(Clone)]
pub struct GptLiveAuth {
    token: String,
    account_id: String,
}

impl GptLiveAuth {
    pub fn oauth(token: &str, account_id: &str) -> Result<Self, String> {
        let token = token.trim();
        let account_id = account_id.trim();
        if token.is_empty() {
            return Err("GPT-Live OAuth token is missing".into());
        }
        if token.chars().any(char::is_whitespace) {
            return Err("GPT-Live OAuth token contains whitespace".into());
        }
        if !is_safe_identifier(account_id) {
            return Err("GPT-Live account id contains invalid characters".into());
        }
        Ok(Self {
            token: token.into(),
            account_id: account_id.into(),
        })
    }
}

impl fmt::Debug for GptLiveAuth {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GptLiveAuth")
            .field("token", &"[REDACTED]")
            .field("account_id", &"[REDACTED]")
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RequestIds {
    pub realtime_session_id: String,
    pub session_id: String,
    pub thread_id: String,
}

impl RequestIds {
    pub fn new() -> Self {
        Self {
            realtime_session_id: Uuid::new_v4().to_string(),
            session_id: Uuid::new_v4().to_string(),
            thread_id: Uuid::new_v4().to_string(),
        }
    }
}

impl Default for RequestIds {
    fn default() -> Self {
        Self::new()
    }
}

pub fn auth_headers(
    auth: &GptLiveAuth,
    request_ids: &RequestIds,
) -> Result<BTreeMap<String, String>, String> {
    for value in [
        &request_ids.realtime_session_id,
        &request_ids.session_id,
        &request_ids.thread_id,
    ] {
        if !is_safe_identifier(value) {
            return Err("GPT-Live request id contains invalid characters".into());
        }
    }
    Ok(BTreeMap::from([
        ("Authorization".into(), format!("Bearer {}", auth.token)),
        ("OpenAI-Alpha".into(), "quicksilver=v2".into()),
        ("chatgpt-account-id".into(), auth.account_id.clone()),
        ("session-id".into(), request_ids.session_id.clone()),
        ("thread-id".into(), request_ids.thread_id.clone()),
        (
            "x-session-id".into(),
            request_ids.realtime_session_id.clone(),
        ),
    ]))
}

pub fn sideband_auth_headers(
    auth: &GptLiveAuth,
    request_ids: &RequestIds,
) -> Result<BTreeMap<String, String>, String> {
    let mut headers = auth_headers(auth, request_ids)?;
    let version = env!("CARGO_PKG_VERSION");
    headers.insert("originator".into(), "arco".into());
    headers.insert("version".into(), version.into());
    headers.insert("User-Agent".into(), format!("arco/{version}"));
    Ok(headers)
}

#[derive(Clone)]
pub struct GptLiveCallRequest {
    url: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

impl GptLiveCallRequest {
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn headers(&self) -> &BTreeMap<String, String> {
        &self.headers
    }

    pub fn body(&self) -> &[u8] {
        &self.body
    }
}

impl fmt::Debug for GptLiveCallRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let header_names = self.headers.keys().cloned().collect::<Vec<_>>();
        formatter
            .debug_struct("GptLiveCallRequest")
            .field("url", &self.url)
            .field("header_names", &header_names)
            .field("credentials", &"[REDACTED]")
            .field("body_bytes", &self.body.len())
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawGptLiveCallResponse {
    pub status: u16,
    pub location: Option<String>,
    pub openai_session_id: Option<String>,
    pub body: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GptLiveCallResponse {
    pub status: u16,
    pub answer_sdp: String,
    pub call_id: String,
    pub sideband_url: String,
}

pub trait GptLiveCallTransport {
    fn post(&self, request: &GptLiveCallRequest) -> Result<RawGptLiveCallResponse, String>;
}

pub fn create_call_with_transport<T: GptLiveCallTransport>(
    transport: &T,
    auth: &GptLiveAuth,
    request_ids: &RequestIds,
    offer_sdp: &str,
    session: &GptLiveSession,
) -> Result<GptLiveCallResponse, String> {
    let request = build_call_request(auth, request_ids, offer_sdp, session)?;
    let response = transport.post(&request)?;
    parse_call_response(response, auth)
}

fn build_call_request(
    auth: &GptLiveAuth,
    request_ids: &RequestIds,
    offer_sdp: &str,
    session: &GptLiveSession,
) -> Result<GptLiveCallRequest, String> {
    if offer_sdp.trim().is_empty() {
        return Err("GPT-Live SDP offer is empty".into());
    }
    if offer_sdp.len() > MAX_SDP_BYTES {
        return Err("GPT-Live SDP offer is too large".into());
    }
    let mut headers = sideband_auth_headers(auth, request_ids)?;
    headers.insert("Content-Type".into(), "application/json".into());
    let body = serde_json::to_vec(&json!({ "sdp": offer_sdp, "session": session }))
        .map_err(|_| "GPT-Live call request could not be encoded".to_string())?;
    Ok(GptLiveCallRequest {
        url: CHATGPT_GPT_LIVE_CALL_URL.into(),
        headers,
        body,
    })
}

fn parse_call_response(
    response: RawGptLiveCallResponse,
    auth: &GptLiveAuth,
) -> Result<GptLiveCallResponse, String> {
    if !(200..300).contains(&response.status) {
        let detail = if response.body.len() > MAX_ERROR_BODY_BYTES {
            String::new()
        } else {
            String::from_utf8(response.body)
                .ok()
                .map(|value| redact_provider_error(value.trim(), auth))
                .unwrap_or_default()
                .chars()
                .take(MAX_ERROR_DETAIL_CHARS)
                .collect::<String>()
        };
        let suffix = if detail.is_empty() {
            String::new()
        } else {
            format!(": {detail}")
        };
        return Err(format!(
            "GPT-Live rejected the session ({}){suffix}",
            response.status
        ));
    }
    if response.body.len() > MAX_SDP_BYTES {
        return Err("GPT-Live call response SDP answer is too large".into());
    }
    let answer_sdp = String::from_utf8(response.body)
        .map_err(|_| "GPT-Live call response SDP answer is not valid UTF-8".to_string())?;
    if answer_sdp.trim().is_empty() {
        return Err("GPT-Live call response SDP answer is empty".into());
    }
    let call_id = extract_call_id(
        response.location.as_deref(),
        response.openai_session_id.as_deref(),
    )?;
    let sideband_url = build_sideband_url(&call_id)?;
    Ok(GptLiveCallResponse {
        status: response.status,
        answer_sdp,
        call_id,
        sideband_url,
    })
}

#[derive(Clone, Debug)]
pub struct UreqGptLiveCallTransport {
    timeout: Duration,
}

impl UreqGptLiveCallTransport {
    pub fn new(timeout: Duration) -> Result<Self, String> {
        if timeout.is_zero() || timeout > Duration::from_secs(120) {
            return Err("GPT-Live call timeout must be between 1 ms and 120 seconds".into());
        }
        Ok(Self { timeout })
    }
}

impl Default for UreqGptLiveCallTransport {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(30),
        }
    }
}

impl GptLiveCallTransport for UreqGptLiveCallTransport {
    fn post(&self, request: &GptLiveCallRequest) -> Result<RawGptLiveCallResponse, String> {
        if request.url != CHATGPT_GPT_LIVE_CALL_URL {
            return Err("GPT-Live call transport refused an unexpected URL".into());
        }
        let agent = ureq::AgentBuilder::new()
            .redirects(0)
            .try_proxy_from_env(true)
            .timeout_connect(self.timeout)
            .timeout_read(self.timeout)
            .timeout_write(self.timeout)
            .build();
        let mut outgoing = agent.post(&request.url);
        for (name, value) in &request.headers {
            outgoing = outgoing.set(name, value);
        }
        let response = match outgoing.send_bytes(&request.body) {
            Ok(response) => response,
            Err(ureq::Error::Status(_, response)) => response,
            Err(ureq::Error::Transport(error)) => {
                return Err(format!("GPT-Live call request failed: {error}"))
            }
        };
        let status = response.status();
        let location = response.header("Location").map(str::to_string);
        let openai_session_id = response.header("openai-session-id").map(str::to_string);
        let body_limit = if (200..300).contains(&status) {
            MAX_SDP_BYTES
        } else {
            MAX_ERROR_BODY_BYTES
        };
        let mut body = Vec::new();
        response
            .into_reader()
            .take((body_limit + 1) as u64)
            .read_to_end(&mut body)
            .map_err(|error| format!("GPT-Live call response could not be read: {error}"))?;
        Ok(RawGptLiveCallResponse {
            status,
            location,
            openai_session_id,
            body,
        })
    }
}

pub fn redact_provider_error(text: &str, auth: &GptLiveAuth) -> String {
    let mut redacted = text.replace(&auth.token, "[REDACTED]");
    redacted = redacted.replace(&auth.account_id, "[REDACTED]");
    let redacted = bearer_pattern()
        .replace_all(&redacted, "Bearer [REDACTED]")
        .into_owned();
    assignment_pattern()
        .replace_all(&redacted, "$1=[REDACTED]")
        .into_owned()
}

fn bearer_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| Regex::new(r"(?i)Bearer\s+[^\s,;]+").expect("valid bearer regex"))
}

fn assignment_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r"(?i)\b(token|account)=([^\s,;]+)").expect("valid credential regex")
    })
}
