use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fmt;
use std::io::Read;
use std::sync::OnceLock;
use std::time::Duration;
use url::form_urlencoded::Serializer;
use url::Url;
use uuid::Uuid;

pub const OPENAI_OAUTH_CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const OPENAI_OAUTH_AUTHORIZE_URL: &str = "https://auth.openai.com/oauth/authorize";
pub const OPENAI_OAUTH_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
pub const OPENAI_OAUTH_CALLBACK_PORT: u16 = 1455;
pub const OPENAI_OAUTH_CALLBACK_PATH: &str = "/auth/callback";
pub const OPENAI_OAUTH_CALLBACK_HOST: &str = "localhost";

const TOKEN_ERROR_MAX_CHARS: usize = 500;
const TOKEN_RESPONSE_MAX_BYTES: usize = 64 * 1024;
const CREDENTIAL_BLOB_MAX_BYTES: usize = 64 * 1024;
const KEYCHAIN_SERVICE: &str = "app.arco.desktop.gpt-live-beta.v1";
const KEYCHAIN_ACCOUNT: &str = "oauth";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthorizationFlow {
    pub verifier: String,
    pub state: String,
    pub redirect_uri: String,
    pub code_challenge: String,
    pub authorization_url: String,
}

pub fn create_authorization_flow(callback_host: &str) -> Result<AuthorizationFlow, String> {
    let verifier = format!(
        "{}{}{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    );
    let state = Uuid::new_v4().simple().to_string();
    authorization_flow_with_material(callback_host, &verifier, &state)
}

pub fn create_default_authorization_flow() -> Result<AuthorizationFlow, String> {
    create_authorization_flow(OPENAI_OAUTH_CALLBACK_HOST)
}

pub fn authorization_flow_with_material(
    callback_host: &str,
    verifier: &str,
    state: &str,
) -> Result<AuthorizationFlow, String> {
    validate_callback_host(callback_host)?;
    validate_pkce_verifier(verifier)?;
    if state.is_empty() || state.len() > 256 || !state.is_ascii() {
        return Err("OpenAI OAuth state is invalid".into());
    }

    let redirect_host = if callback_host == "::1" {
        "[::1]"
    } else {
        callback_host
    };
    let redirect_uri =
        format!("http://{redirect_host}:{OPENAI_OAUTH_CALLBACK_PORT}{OPENAI_OAUTH_CALLBACK_PATH}");
    let code_challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
    let mut authorization_url =
        Url::parse(OPENAI_OAUTH_AUTHORIZE_URL).map_err(|_| "OpenAI OAuth URL is invalid")?;
    authorization_url
        .query_pairs_mut()
        .append_pair("response_type", "code")
        .append_pair("client_id", OPENAI_OAUTH_CLIENT_ID)
        .append_pair("redirect_uri", &redirect_uri)
        .append_pair("scope", "openid profile email offline_access")
        .append_pair("code_challenge", &code_challenge)
        .append_pair("code_challenge_method", "S256")
        .append_pair("state", state)
        .append_pair("originator", "arco")
        .append_pair("id_token_add_organizations", "true")
        .append_pair("codex_cli_simplified_flow", "true");

    Ok(AuthorizationFlow {
        verifier: verifier.into(),
        state: state.into(),
        redirect_uri,
        code_challenge,
        authorization_url: authorization_url.into(),
    })
}

fn validate_callback_host(host: &str) -> Result<(), String> {
    match host {
        "127.0.0.1" | "localhost" | "::1" => Ok(()),
        _ => Err("OpenAI OAuth callback must use a loopback host".into()),
    }
}

fn validate_pkce_verifier(verifier: &str) -> Result<(), String> {
    if !(43..=128).contains(&verifier.len())
        || !verifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~'))
    {
        return Err("OpenAI OAuth PKCE verifier is invalid".into());
    }
    Ok(())
}

pub fn parse_callback_url(callback_url: &str, expected_state: &str) -> Result<String, String> {
    let url = Url::parse(callback_url).map_err(|_| "OpenAI OAuth callback URL is invalid")?;
    let host = url
        .host_str()
        .ok_or_else(|| "OpenAI OAuth callback host is missing".to_string())?;
    validate_callback_host(host)?;
    if url.scheme() != "http"
        || url.port_or_known_default() != Some(OPENAI_OAUTH_CALLBACK_PORT)
        || url.path() != OPENAI_OAUTH_CALLBACK_PATH
    {
        return Err("OpenAI OAuth callback URL is invalid".into());
    }

    let params = url
        .query_pairs()
        .into_owned()
        .collect::<std::collections::BTreeMap<_, _>>();
    if params.get("state").map(String::as_str) != Some(expected_state) {
        return Err("OpenAI OAuth callback state did not match".into());
    }
    if params.get("error").map(String::as_str) == Some("access_denied") {
        return Err("OpenAI OAuth login was cancelled or denied".into());
    }
    if params.contains_key("error") {
        return Err("OpenAI OAuth provider returned an error".into());
    }
    params
        .get("code")
        .filter(|code| !code.trim().is_empty())
        .cloned()
        .ok_or_else(|| "OpenAI OAuth callback code is missing".into())
}

pub fn build_exchange_form(code: &str, verifier: &str, redirect_uri: &str) -> String {
    let mut form = Serializer::new(String::new());
    form.append_pair("grant_type", "authorization_code")
        .append_pair("client_id", OPENAI_OAUTH_CLIENT_ID)
        .append_pair("code", code)
        .append_pair("code_verifier", verifier)
        .append_pair("redirect_uri", redirect_uri);
    form.finish()
}

pub fn build_refresh_form(refresh_token: &str) -> String {
    let mut form = Serializer::new(String::new());
    form.append_pair("grant_type", "refresh_token")
        .append_pair("client_id", OPENAI_OAUTH_CLIENT_ID)
        .append_pair("refresh_token", refresh_token);
    form.finish()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenOperation {
    Exchange,
    Refresh,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TokenFailureReason {
    RefreshTokenReused,
    RefreshTokenExpired,
    InvalidRefreshToken,
    InvalidGrant,
    TokenInvalidated,
    Revoked,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TokenFailure {
    pub operation: TokenOperation,
    pub status: Option<u16>,
    pub summary: String,
    pub code: Option<String>,
    pub reason: Option<TokenFailureReason>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TokenResult {
    Success {
        access_token: String,
        refresh_token: String,
        expires_at_ms: u64,
    },
    Failed(TokenFailure),
}

#[derive(Clone)]
pub struct OAuthTokenRequest {
    url: String,
    headers: BTreeMap<String, String>,
    body: String,
}

impl OAuthTokenRequest {
    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn headers(&self) -> &BTreeMap<String, String> {
        &self.headers
    }

    pub fn body(&self) -> &str {
        &self.body
    }
}

impl fmt::Debug for OAuthTokenRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OAuthTokenRequest")
            .field("url", &self.url)
            .field("header_names", &self.headers.keys().collect::<Vec<_>>())
            .field("credentials", &"[REDACTED]")
            .field("body_bytes", &self.body.len())
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RawOAuthTokenResponse {
    pub status: u16,
    pub body: String,
}

pub trait OAuthTokenTransport {
    fn post(&self, request: &OAuthTokenRequest) -> Result<RawOAuthTokenResponse, String>;
}

pub fn exchange_token_with_transport<T: OAuthTokenTransport>(
    transport: &T,
    code: &str,
    verifier: &str,
    redirect_uri: &str,
    now_ms: u64,
) -> TokenResult {
    request_token_with_transport(
        transport,
        TokenOperation::Exchange,
        build_exchange_form(code, verifier, redirect_uri),
        None,
        Some(code),
        now_ms,
    )
}

pub fn refresh_token_with_transport<T: OAuthTokenTransport>(
    transport: &T,
    refresh_token: &str,
    now_ms: u64,
) -> TokenResult {
    request_token_with_transport(
        transport,
        TokenOperation::Refresh,
        build_refresh_form(refresh_token),
        Some(refresh_token),
        Some(refresh_token),
        now_ms,
    )
}

fn request_token_with_transport<T: OAuthTokenTransport>(
    transport: &T,
    operation: TokenOperation,
    body: String,
    existing_refresh_token: Option<&str>,
    request_secret: Option<&str>,
    now_ms: u64,
) -> TokenResult {
    let request = OAuthTokenRequest {
        url: OPENAI_OAUTH_TOKEN_URL.into(),
        headers: BTreeMap::from([
            (
                "Content-Type".into(),
                "application/x-www-form-urlencoded".into(),
            ),
            ("Accept".into(), "application/json".into()),
        ]),
        body,
    };
    match transport.post(&request) {
        Ok(response) => {
            let result = parse_token_response(
                operation,
                response.status,
                &response.body,
                existing_refresh_token,
                now_ms,
            );
            match result {
                TokenResult::Failed(mut failure) => {
                    failure.summary = redact_token_error(&failure.summary, request_secret);
                    TokenResult::Failed(failure)
                }
                success => success,
            }
        }
        Err(error) => failed_token_response(
            operation,
            None,
            &format!("OpenAI OAuth token request failed: {error}"),
            None,
            request_secret,
        ),
    }
}

#[derive(Clone, Debug)]
pub struct UreqOAuthTokenTransport {
    timeout: Duration,
}

impl UreqOAuthTokenTransport {
    pub fn new(timeout: Duration) -> Result<Self, String> {
        if timeout.is_zero() || timeout > Duration::from_secs(120) {
            return Err("OpenAI OAuth timeout must be between 1 ms and 120 seconds".into());
        }
        Ok(Self { timeout })
    }
}

impl Default for UreqOAuthTokenTransport {
    fn default() -> Self {
        Self {
            timeout: Duration::from_secs(30),
        }
    }
}

fn build_openai_ureq_agent(timeout: Duration) -> ureq::Agent {
    ureq::AgentBuilder::new()
        .redirects(0)
        .try_proxy_from_env(true)
        .timeout_connect(timeout)
        .timeout_read(timeout)
        .timeout_write(timeout)
        .build()
}

impl OAuthTokenTransport for UreqOAuthTokenTransport {
    fn post(&self, request: &OAuthTokenRequest) -> Result<RawOAuthTokenResponse, String> {
        if request.url != OPENAI_OAUTH_TOKEN_URL {
            return Err("OpenAI OAuth transport refused an unexpected URL".into());
        }
        let agent = build_openai_ureq_agent(self.timeout);
        let mut outgoing = agent.post(&request.url);
        for (name, value) in &request.headers {
            outgoing = outgoing.set(name, value);
        }
        let response = match outgoing.send_string(&request.body) {
            Ok(response) => response,
            Err(ureq::Error::Status(_, response)) => response,
            Err(ureq::Error::Transport(error)) => return Err(error.to_string()),
        };
        let status = response.status();
        let mut bytes = Vec::new();
        response
            .into_reader()
            .take((TOKEN_RESPONSE_MAX_BYTES + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|error| format!("could not read token response: {error}"))?;
        if bytes.len() > TOKEN_RESPONSE_MAX_BYTES {
            return Err("OpenAI OAuth token response is too large".into());
        }
        let body = String::from_utf8(bytes)
            .map_err(|_| "OpenAI OAuth token response is not valid UTF-8".to_string())?;
        Ok(RawOAuthTokenResponse { status, body })
    }
}

pub fn parse_token_response(
    operation: TokenOperation,
    status: u16,
    body: &str,
    existing_refresh_token: Option<&str>,
    now_ms: u64,
) -> TokenResult {
    let parsed = match serde_json::from_str::<Value>(body) {
        Ok(value) => value,
        Err(_) => {
            return failed_token_response(
                operation,
                Some(status),
                "OpenAI OAuth token response was not valid JSON",
                None,
                existing_refresh_token,
            )
        }
    };

    if (200..300).contains(&status) {
        let access_token = parsed
            .get("access_token")
            .and_then(Value::as_str)
            .filter(|token| valid_secret(token));
        let response_refresh_token = parsed
            .get("refresh_token")
            .and_then(Value::as_str)
            .filter(|token| valid_secret(token));
        let refresh_token = response_refresh_token.or(existing_refresh_token);
        let expires_in_seconds = parsed
            .get("expires_in")
            .and_then(Value::as_u64)
            .filter(|seconds| *seconds > 0);
        let expires_at_ms = expires_in_seconds
            .and_then(|seconds| seconds.checked_mul(1_000))
            .and_then(|duration| now_ms.checked_add(duration));

        if let (Some(access_token), Some(refresh_token), Some(expires_at_ms)) =
            (access_token, refresh_token, expires_at_ms)
        {
            return TokenResult::Success {
                access_token: access_token.into(),
                refresh_token: refresh_token.into(),
                expires_at_ms,
            };
        }
        return failed_token_response(
            operation,
            Some(status),
            "OpenAI OAuth token response was missing required credentials or expiry",
            None,
            existing_refresh_token,
        );
    }

    let code = read_error_code(&parsed);
    let message = read_error_message(&parsed)
        .unwrap_or_else(|| format!("OpenAI OAuth token request failed with HTTP {status}"));
    failed_token_response(
        operation,
        Some(status),
        &message,
        code.as_deref(),
        existing_refresh_token,
    )
}

fn valid_secret(token: &str) -> bool {
    !token.is_empty() && !token.chars().any(char::is_whitespace)
}

fn read_error_code(value: &Value) -> Option<String> {
    value
        .get("error")
        .and_then(|error| {
            error
                .get("code")
                .and_then(Value::as_str)
                .or_else(|| error.as_str())
        })
        .or_else(|| value.get("code").and_then(Value::as_str))
        .filter(|code| !code.trim().is_empty())
        .map(|code| code.trim().to_string())
}

fn read_error_message(value: &Value) -> Option<String> {
    value
        .get("error_description")
        .and_then(Value::as_str)
        .or_else(|| {
            value
                .get("error")
                .and_then(|error| error.get("message"))
                .and_then(Value::as_str)
        })
        .or_else(|| value.get("message").and_then(Value::as_str))
        .or_else(|| value.get("error").and_then(Value::as_str))
        .filter(|message| !message.trim().is_empty())
        .map(|message| message.trim().to_string())
}

fn failed_token_response(
    operation: TokenOperation,
    status: Option<u16>,
    summary: &str,
    code: Option<&str>,
    secret: Option<&str>,
) -> TokenResult {
    let reason = code.and_then(classify_failure);
    TokenResult::Failed(TokenFailure {
        operation,
        status,
        summary: redact_token_error(summary, secret),
        code: code.map(str::to_string),
        reason,
    })
}

fn classify_failure(code: &str) -> Option<TokenFailureReason> {
    match code.to_ascii_lowercase().as_str() {
        "refresh_token_reused" => Some(TokenFailureReason::RefreshTokenReused),
        "refresh_token_expired" => Some(TokenFailureReason::RefreshTokenExpired),
        "invalid_refresh_token" => Some(TokenFailureReason::InvalidRefreshToken),
        "invalid_grant" => Some(TokenFailureReason::InvalidGrant),
        "token_invalidated" | "refresh_token_invalidated" => {
            Some(TokenFailureReason::TokenInvalidated)
        }
        "revoked" | "token_revoked" => Some(TokenFailureReason::Revoked),
        _ => None,
    }
}

fn redact_token_error(message: &str, exact_secret: Option<&str>) -> String {
    static BEARER_RE: OnceLock<Regex> = OnceLock::new();
    static TOKEN_ASSIGNMENT_RE: OnceLock<Regex> = OnceLock::new();
    let mut redacted = message.to_string();
    if let Some(secret) = exact_secret.filter(|secret| !secret.is_empty()) {
        redacted = redacted.replace(secret, "[REDACTED]");
    }
    redacted = BEARER_RE
        .get_or_init(|| Regex::new(r"(?i)bearer\s+[A-Za-z0-9._~+/-]+=*").expect("valid regex"))
        .replace_all(&redacted, "Bearer [REDACTED]")
        .into_owned();
    redacted = TOKEN_ASSIGNMENT_RE
        .get_or_init(|| {
            Regex::new(r"(?i)(access_token|refresh_token|id_token)=([^\s&]+)").expect("valid regex")
        })
        .replace_all(&redacted, "$1=[REDACTED]")
        .into_owned();
    redacted
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(TOKEN_ERROR_MAX_CHARS)
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthIdentity {
    pub account_id: String,
    pub plan_type: Option<String>,
    pub email: Option<String>,
}

pub fn extract_auth_identity(access_token: &str) -> Result<AuthIdentity, String> {
    let payload = access_token
        .split('.')
        .nth(1)
        .filter(|payload| !payload.is_empty())
        .ok_or_else(|| "OpenAI OAuth access token is not a JWT".to_string())?;
    let decoded = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| "OpenAI OAuth access token payload is invalid")?;
    let claims = serde_json::from_slice::<Value>(&decoded)
        .map_err(|_| "OpenAI OAuth access token claims are invalid")?;
    let auth = claims
        .get("https://api.openai.com/auth")
        .and_then(Value::as_object)
        .ok_or_else(|| "OpenAI OAuth account claims are missing".to_string())?;
    let account_id = auth
        .get("chatgpt_account_id")
        .and_then(Value::as_str)
        .filter(|value| valid_identity_value(value))
        .ok_or_else(|| "OpenAI OAuth account ID is missing".to_string())?;
    let plan_type = auth
        .get("chatgpt_plan_type")
        .and_then(Value::as_str)
        .filter(|value| valid_identity_value(value))
        .map(str::to_string);
    let email = claims
        .get("https://api.openai.com/profile")
        .and_then(|profile| profile.get("email"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && !value.chars().any(char::is_control))
        .map(str::to_string);

    Ok(AuthIdentity {
        account_id: account_id.into(),
        plan_type,
        email,
    })
}

fn valid_identity_value(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

#[derive(Clone)]
pub struct GptLiveCredentials {
    access_token: String,
    refresh_token: String,
    account_id: String,
    expires_at_ms: u64,
    email: Option<String>,
    plan_type: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredGptLiveCredentials {
    version: u8,
    access_token: String,
    refresh_token: String,
    account_id: String,
    expires_at_ms: u64,
    email: Option<String>,
    plan_type: Option<String>,
}

pub trait GptLiveCredentialStorage {
    fn load(&self) -> Result<Option<Vec<u8>>, String>;
    fn save(&self, value: &[u8]) -> Result<(), String>;
    fn delete(&self) -> Result<(), String>;
}

pub fn save_credentials_to<T: GptLiveCredentialStorage>(
    storage: &T,
    credentials: &GptLiveCredentials,
) -> Result<(), String> {
    let stored = StoredGptLiveCredentials {
        version: 1,
        access_token: credentials.access_token.clone(),
        refresh_token: credentials.refresh_token.clone(),
        account_id: credentials.account_id.clone(),
        expires_at_ms: credentials.expires_at_ms,
        email: credentials.email.clone(),
        plan_type: credentials.plan_type.clone(),
    };
    let bytes = serde_json::to_vec(&stored)
        .map_err(|_| "OpenAI OAuth credentials could not be encoded".to_string())?;
    if bytes.len() > CREDENTIAL_BLOB_MAX_BYTES {
        return Err("OpenAI OAuth credentials are too large".into());
    }
    storage.save(&bytes)
}

pub fn load_credentials_from<T: GptLiveCredentialStorage>(
    storage: &T,
) -> Result<Option<GptLiveCredentials>, String> {
    let Some(bytes) = storage.load()? else {
        return Ok(None);
    };
    if bytes.len() > CREDENTIAL_BLOB_MAX_BYTES {
        return Err("OpenAI OAuth credentials in Keychain are too large".into());
    }
    let stored = serde_json::from_slice::<StoredGptLiveCredentials>(&bytes)
        .map_err(|_| "OpenAI OAuth credentials in Keychain are invalid".to_string())?;
    if stored.version != 1 {
        return Err("OpenAI OAuth credentials in Keychain use an unsupported version".into());
    }
    GptLiveCredentials::new(
        &stored.access_token,
        &stored.refresh_token,
        &stored.account_id,
        stored.expires_at_ms,
        stored.email,
        stored.plan_type,
    )
    .map(Some)
}

#[derive(Clone, Copy, Debug, Default)]
pub struct MacOSGptLiveCredentialStorage;

impl GptLiveCredentialStorage for MacOSGptLiveCredentialStorage {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        #[cfg(target_os = "macos")]
        {
            match security_framework::passwords::get_generic_password(
                KEYCHAIN_SERVICE,
                KEYCHAIN_ACCOUNT,
            ) {
                Ok(bytes) => Ok(Some(bytes)),
                Err(error) if error.code() == -25300 => Ok(None),
                Err(error) => Err(format!(
                    "could not read OpenAI OAuth credentials from Keychain: {error}"
                )),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Ok(None)
        }
    }

    fn save(&self, value: &[u8]) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            use security_framework::os::macos::keychain::SecKeychain;
            let keychain = SecKeychain::default()
                .map_err(|error| format!("could not open the login Keychain: {error}"))?;
            keychain
                .set_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, value)
                .map_err(|error| {
                    format!("could not save OpenAI OAuth credentials to Keychain: {error}")
                })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = value;
            Err("Arco stores OpenAI OAuth credentials in macOS Keychain.".into())
        }
    }

    fn delete(&self) -> Result<(), String> {
        #[cfg(target_os = "macos")]
        {
            match security_framework::passwords::delete_generic_password(
                KEYCHAIN_SERVICE,
                KEYCHAIN_ACCOUNT,
            ) {
                Ok(()) => Ok(()),
                Err(error) if error.code() == -25300 => Ok(()),
                Err(error) => Err(format!(
                    "could not remove OpenAI OAuth credentials from Keychain: {error}"
                )),
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Err("Arco stores OpenAI OAuth credentials in macOS Keychain.".into())
        }
    }
}

impl GptLiveCredentials {
    pub fn new(
        access_token: &str,
        refresh_token: &str,
        account_id: &str,
        expires_at_ms: u64,
        email: Option<String>,
        plan_type: Option<String>,
    ) -> Result<Self, String> {
        if !valid_secret(access_token) || !valid_secret(refresh_token) {
            return Err("OpenAI OAuth credentials are invalid".into());
        }
        if !valid_identity_value(account_id) || expires_at_ms == 0 {
            return Err("OpenAI OAuth credential metadata is invalid".into());
        }
        if email
            .as_deref()
            .is_some_and(|value| !valid_display_value(value, 320))
            || plan_type
                .as_deref()
                .is_some_and(|value| !valid_identity_value(value))
        {
            return Err("OpenAI OAuth display metadata is invalid".into());
        }
        Ok(Self {
            access_token: access_token.into(),
            refresh_token: refresh_token.into(),
            account_id: account_id.into(),
            expires_at_ms,
            email,
            plan_type,
        })
    }

    pub fn access_token(&self) -> &str {
        &self.access_token
    }

    pub fn refresh_token(&self) -> &str {
        &self.refresh_token
    }

    pub fn account_id(&self) -> &str {
        &self.account_id
    }

    pub fn expires_at_ms(&self) -> u64 {
        self.expires_at_ms
    }

    pub fn email(&self) -> Option<&str> {
        self.email.as_deref()
    }

    pub fn plan_type(&self) -> Option<&str> {
        self.plan_type.as_deref()
    }

    pub fn status(&self, now_ms: u64) -> GptLiveCredentialStatus {
        GptLiveCredentialStatus {
            configured: true,
            valid: self.expires_at_ms > now_ms,
            account_id: Some(self.account_id.clone()),
            expires_at_ms: Some(self.expires_at_ms),
            email: self.email.clone(),
            plan_type: self.plan_type.clone(),
        }
    }
}

fn valid_display_value(value: &str, max_chars: usize) -> bool {
    !value.is_empty() && value.chars().count() <= max_chars && !value.chars().any(char::is_control)
}

impl fmt::Debug for GptLiveCredentials {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GptLiveCredentials")
            .field("access_token", &"[REDACTED]")
            .field("refresh_token", &"[REDACTED]")
            .field("account_id", &self.account_id)
            .field("expires_at_ms", &self.expires_at_ms)
            .field("email", &self.email)
            .field("plan_type", &self.plan_type)
            .finish()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GptLiveCredentialStatus {
    pub configured: bool,
    pub valid: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expires_at_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plan_type: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static PROXY_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn openai_http_agent_uses_the_configured_environment_proxy() {
        let _guard = PROXY_ENV_LOCK.lock().unwrap();
        let keys = [
            "ALL_PROXY",
            "all_proxy",
            "HTTPS_PROXY",
            "https_proxy",
            "HTTP_PROXY",
            "http_proxy",
        ];
        let previous = keys.map(|key| (key, std::env::var_os(key)));
        for key in keys {
            std::env::remove_var(key);
        }
        std::env::set_var("HTTPS_PROXY", "http://proxy.example.test:8765");

        let agent = build_openai_ureq_agent(Duration::from_secs(1));
        let debug = format!("{agent:?}");

        for (key, value) in previous {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
        assert!(debug.contains("proxy.example.test"));
        assert!(debug.contains("8765"));
    }
}
