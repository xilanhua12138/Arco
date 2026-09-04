use arco_core::gpt_live_oauth::{
    authorization_flow_with_material, build_exchange_form, build_refresh_form,
    create_default_authorization_flow, exchange_token_with_transport, extract_auth_identity,
    load_credentials_from, parse_callback_url, parse_token_response, refresh_token_with_transport,
    save_credentials_to, GptLiveCredentialStorage, GptLiveCredentials, OAuthTokenRequest,
    OAuthTokenTransport, RawOAuthTokenResponse, TokenFailureReason, TokenOperation, TokenResult,
};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use std::cell::{Cell, RefCell};

const RFC_7636_VERIFIER: &str = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const RFC_7636_CHALLENGE: &str = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

fn jwt(payload: serde_json::Value) -> String {
    format!(
        "header.{}.signature",
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap())
    )
}

#[test]
fn authorization_flow_uses_pkce_and_an_exact_loopback_callback() {
    let flow =
        authorization_flow_with_material("127.0.0.1", RFC_7636_VERIFIER, "state-123").unwrap();
    let url = url::Url::parse(&flow.authorization_url).unwrap();
    let query = url
        .query_pairs()
        .collect::<std::collections::BTreeMap<_, _>>();

    assert_eq!(flow.redirect_uri, "http://127.0.0.1:1455/auth/callback");
    assert_eq!(flow.code_challenge, RFC_7636_CHALLENGE);
    assert_eq!(url.scheme(), "https");
    assert_eq!(url.host_str(), Some("auth.openai.com"));
    assert_eq!(url.path(), "/oauth/authorize");
    assert_eq!(query.get("response_type").unwrap(), "code");
    assert_eq!(query.get("code_challenge").unwrap(), RFC_7636_CHALLENGE);
    assert_eq!(query.get("code_challenge_method").unwrap(), "S256");
    assert_eq!(query.get("state").unwrap(), "state-123");
    assert_eq!(query.get("originator").unwrap(), "arco");
    assert_eq!(
        query.get("scope").unwrap(),
        "openid profile email offline_access"
    );
}

#[test]
fn default_authorization_flow_uses_the_provider_registered_localhost_callback() {
    let flow = create_default_authorization_flow().unwrap();

    assert_eq!(flow.redirect_uri, "http://localhost:1455/auth/callback");
    assert!(flow
        .authorization_url
        .contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"));
}

#[test]
fn oauth_callback_rejects_non_loopback_wrong_path_state_and_provider_error() {
    assert_eq!(
        parse_callback_url(
            "http://127.0.0.1:1455/auth/callback?code=abc&state=state-123",
            "state-123"
        )
        .unwrap(),
        "abc"
    );
    assert_eq!(
        parse_callback_url(
            "http://localhost:1455/auth/callback?code=abc&state=wrong",
            "state-123"
        )
        .unwrap_err(),
        "OpenAI OAuth callback state did not match"
    );
    assert!(parse_callback_url(
        "https://example.test/auth/callback?code=abc&state=state-123",
        "state-123"
    )
    .is_err());
    assert!(parse_callback_url(
        "http://localhost:1455/other?code=abc&state=state-123",
        "state-123"
    )
    .is_err());
    assert_eq!(
        parse_callback_url(
            "http://localhost:1455/auth/callback?error=access_denied&error_description=User%20cancelled&state=state-123",
            "state-123"
        )
        .unwrap_err(),
        "OpenAI OAuth login was cancelled or denied"
    );
}

#[test]
fn token_forms_encode_values_and_never_put_secrets_in_the_url() {
    let exchange = build_exchange_form(
        "code+/= value",
        "verifier+/= value",
        "http://127.0.0.1:1455/auth/callback",
    );
    let refresh = build_refresh_form("refresh+/= value");

    assert!(exchange.contains("grant_type=authorization_code"));
    assert!(exchange.contains("code=code%2B%2F%3D+value"));
    assert!(exchange.contains("code_verifier=verifier%2B%2F%3D+value"));
    assert!(refresh.contains("grant_type=refresh_token"));
    assert!(refresh.contains("refresh_token=refresh%2B%2F%3D+value"));
    assert!(!exchange.contains("auth.openai.com"));
    assert!(!refresh.contains("auth.openai.com"));
}

#[test]
fn token_success_requires_access_refresh_and_finite_positive_expiry() {
    let result = parse_token_response(
        TokenOperation::Exchange,
        200,
        r#"{"access_token":"access","refresh_token":"refresh","expires_in":3600}"#,
        None,
        1_000,
    );

    assert_eq!(
        result,
        TokenResult::Success {
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            expires_at_ms: 3_601_000,
        }
    );

    for body in [
        r#"{"refresh_token":"refresh","expires_in":3600}"#,
        r#"{"access_token":"access","expires_in":3600}"#,
        r#"{"access_token":"access","refresh_token":"refresh","expires_in":0}"#,
        r#"{"access_token":"access","refresh_token":"refresh","expires_in":1e309}"#,
        "not json",
    ] {
        assert!(matches!(
            parse_token_response(TokenOperation::Exchange, 200, body, None, 1_000),
            TokenResult::Failed(_)
        ));
    }
}

#[test]
fn token_refresh_keeps_the_existing_refresh_token_when_not_rotated() {
    assert_eq!(
        parse_token_response(
            TokenOperation::Refresh,
            200,
            r#"{"access_token":"new-access","expires_in":60}"#,
            Some("existing-refresh"),
            5_000,
        ),
        TokenResult::Success {
            access_token: "new-access".into(),
            refresh_token: "existing-refresh".into(),
            expires_at_ms: 65_000,
        }
    );
}

#[test]
fn token_failure_classifies_reused_refresh_without_echoing_secrets() {
    let result = parse_token_response(
        TokenOperation::Refresh,
        400,
        r#"{"error":{"code":"refresh_token_reused","message":"refresh secret-refresh was reused"}}"#,
        Some("secret-refresh"),
        0,
    );

    let TokenResult::Failed(failure) = result else {
        panic!("expected a failed token response");
    };
    assert_eq!(failure.status, Some(400));
    assert_eq!(failure.reason, Some(TokenFailureReason::RefreshTokenReused));
    assert!(!failure.summary.contains("secret-refresh"));
    assert!(failure.summary.contains("[REDACTED]"));

    let invalidated = parse_token_response(
        TokenOperation::Refresh,
        400,
        r#"{"error":{"code":"refresh_token_invalidated","message":"sign in again"}}"#,
        Some("refresh"),
        0,
    );
    let TokenResult::Failed(invalidated) = invalidated else {
        panic!("expected an invalidated token failure");
    };
    assert_eq!(
        invalidated.reason,
        Some(TokenFailureReason::TokenInvalidated)
    );
}

#[test]
fn oauth_identity_is_read_from_the_namespaced_jwt_claims() {
    let access_token = jwt(serde_json::json!({
        "https://api.openai.com/auth": {
            "chatgpt_account_id": "acct-123",
            "chatgpt_plan_type": "pro"
        },
        "https://api.openai.com/profile": {
            "email": "person@example.com"
        }
    }));

    let identity = extract_auth_identity(&access_token).unwrap();

    assert_eq!(identity.account_id, "acct-123");
    assert_eq!(identity.plan_type.as_deref(), Some("pro"));
    assert_eq!(identity.email.as_deref(), Some("person@example.com"));
    assert!(extract_auth_identity("not-a-jwt").is_err());
}

#[test]
fn credentials_debug_output_and_status_never_contain_tokens() {
    let credentials = GptLiveCredentials::new(
        "secret-access",
        "secret-refresh",
        "acct-123",
        123_456,
        Some("person@example.com".into()),
        Some("pro".into()),
    )
    .unwrap();

    let debug = format!("{credentials:?}");
    let status = credentials.status(100_000);

    assert!(!debug.contains("secret-access"));
    assert!(!debug.contains("secret-refresh"));
    assert!(debug.contains("REDACTED"));
    assert!(status.configured);
    assert!(status.valid);
    assert_eq!(status.account_id.as_deref(), Some("acct-123"));
    assert_eq!(status.plan_type.as_deref(), Some("pro"));
    assert!(!serde_json::to_string(&status).unwrap().contains("secret"));
}

#[test]
fn credentials_reject_untrusted_display_metadata() {
    assert!(GptLiveCredentials::new(
        "access",
        "refresh",
        "acct-123",
        123_456,
        Some("person@example.com\u{1b}[31m".into()),
        Some("pro".into()),
    )
    .is_err());
    assert!(GptLiveCredentials::new(
        "access",
        "refresh",
        "acct-123",
        123_456,
        None,
        Some("pro\nforged".into()),
    )
    .is_err());
}

#[derive(Default)]
struct MemoryCredentialStorage {
    value: RefCell<Option<Vec<u8>>>,
}

impl GptLiveCredentialStorage for MemoryCredentialStorage {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        Ok(self.value.borrow().clone())
    }

    fn save(&self, value: &[u8]) -> Result<(), String> {
        self.value.replace(Some(value.to_vec()));
        Ok(())
    }

    fn delete(&self) -> Result<(), String> {
        self.value.replace(None);
        Ok(())
    }
}

#[test]
fn oauth_credentials_round_trip_only_through_the_secret_store() {
    let storage = MemoryCredentialStorage::default();
    let credentials = GptLiveCredentials::new(
        "secret-access",
        "secret-refresh",
        "acct-123",
        123_456,
        Some("person@example.com".into()),
        Some("pro".into()),
    )
    .unwrap();

    save_credentials_to(&storage, &credentials).unwrap();
    let restored = load_credentials_from(&storage).unwrap().unwrap();

    assert_eq!(restored.access_token(), "secret-access");
    assert_eq!(restored.refresh_token(), "secret-refresh");
    assert_eq!(restored.account_id(), "acct-123");
    assert_eq!(restored.expires_at_ms(), 123_456);
    assert_eq!(restored.email(), Some("person@example.com"));
    assert_eq!(restored.plan_type(), Some("pro"));
    storage.delete().unwrap();
    assert!(load_credentials_from(&storage).unwrap().is_none());
}

struct ScriptedTokenTransport {
    calls: Cell<usize>,
    request: RefCell<Option<OAuthTokenRequest>>,
    response: Result<RawOAuthTokenResponse, String>,
}

impl OAuthTokenTransport for ScriptedTokenTransport {
    fn post(&self, request: &OAuthTokenRequest) -> Result<RawOAuthTokenResponse, String> {
        self.calls.set(self.calls.get() + 1);
        self.request.replace(Some(request.clone()));
        self.response.clone()
    }
}

#[test]
fn token_transport_posts_form_data_and_redacts_the_request_debug_output() {
    let transport = ScriptedTokenTransport {
        calls: Cell::new(0),
        request: RefCell::new(None),
        response: Ok(RawOAuthTokenResponse {
            status: 200,
            body: r#"{"access_token":"access","refresh_token":"refresh","expires_in":60}"#.into(),
        }),
    };

    let result = exchange_token_with_transport(
        &transport,
        "secret-code",
        "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
        "http://127.0.0.1:1455/auth/callback",
        1_000,
    );

    assert_eq!(
        result,
        TokenResult::Success {
            access_token: "access".into(),
            refresh_token: "refresh".into(),
            expires_at_ms: 61_000,
        }
    );
    assert_eq!(transport.calls.get(), 1);
    let request = transport.request.borrow();
    let request = request.as_ref().unwrap();
    assert_eq!(request.url(), "https://auth.openai.com/oauth/token");
    assert_eq!(
        request.headers()["Content-Type"],
        "application/x-www-form-urlencoded"
    );
    assert!(request.body().contains("code=secret-code"));
    let debug = format!("{request:?}");
    assert!(!debug.contains("secret-code"));
    assert!(debug.contains("REDACTED"));
}

#[test]
fn refresh_transport_failure_does_not_echo_the_refresh_token() {
    let transport = ScriptedTokenTransport {
        calls: Cell::new(0),
        request: RefCell::new(None),
        response: Err("network failure included secret-refresh".into()),
    };

    let TokenResult::Failed(failure) =
        refresh_token_with_transport(&transport, "secret-refresh", 1_000)
    else {
        panic!("expected transport failure");
    };

    assert_eq!(failure.operation, TokenOperation::Refresh);
    assert_eq!(failure.status, None);
    assert!(!failure.summary.contains("secret-refresh"));
    assert!(failure.summary.contains("[REDACTED]"));
}

#[test]
fn exchange_provider_failure_does_not_echo_the_authorization_code() {
    let transport = ScriptedTokenTransport {
        calls: Cell::new(0),
        request: RefCell::new(None),
        response: Ok(RawOAuthTokenResponse {
            status: 400,
            body: r#"{"error":{"code":"invalid_grant","message":"secret-code was rejected"}}"#
                .into(),
        }),
    };

    let TokenResult::Failed(failure) = exchange_token_with_transport(
        &transport,
        "secret-code",
        RFC_7636_VERIFIER,
        "http://127.0.0.1:1455/auth/callback",
        1_000,
    ) else {
        panic!("expected provider failure");
    };

    assert_eq!(failure.reason, Some(TokenFailureReason::InvalidGrant));
    assert!(!failure.summary.contains("secret-code"));
    assert!(failure.summary.contains("[REDACTED]"));
}
