use arco_core::gpt_live::{
    create_call_with_transport, GptLiveAuth, GptLiveCallRequest, GptLiveCallResponse,
    GptLiveCallTransport, GptLiveSession, RawGptLiveCallResponse, RequestIds,
    CHATGPT_GPT_LIVE_CALL_URL, GPT_LIVE_FEATURE_LABEL,
};
use std::cell::{Cell, RefCell};

struct ScriptedTransport {
    calls: Cell<usize>,
    captured: RefCell<Option<GptLiveCallRequest>>,
    response: RawGptLiveCallResponse,
}

impl GptLiveCallTransport for ScriptedTransport {
    fn post(&self, request: &GptLiveCallRequest) -> Result<RawGptLiveCallResponse, String> {
        self.calls.set(self.calls.get() + 1);
        self.captured.replace(Some(request.clone()));
        Ok(self.response.clone())
    }
}

fn ids() -> RequestIds {
    RequestIds {
        realtime_session_id: "realtime-1".into(),
        session_id: "session-1".into(),
        thread_id: "thread-1".into(),
    }
}

fn transport(response: RawGptLiveCallResponse) -> ScriptedTransport {
    ScriptedTransport {
        calls: Cell::new(0),
        captured: RefCell::new(None),
        response,
    }
}

#[test]
fn oauth_call_posts_the_json_contract_and_parses_the_answer() {
    let auth = GptLiveAuth::oauth("secret-access", "acct-123").unwrap();
    let session = GptLiveSession::new("Answer briefly.", None, vec![]).unwrap();
    let transport = transport(RawGptLiveCallResponse {
        status: 201,
        location: Some("/v1/live/rtc_call-123?source=test".into()),
        openai_session_id: None,
        body: b"v=0\r\no=answer\r\n".to_vec(),
    });

    let response =
        create_call_with_transport(&transport, &auth, &ids(), "v=0\r\no=offer\r\n", &session)
            .unwrap();

    assert_eq!(transport.calls.get(), 1);
    let request = transport.captured.borrow();
    let request = request.as_ref().unwrap();
    assert_eq!(request.url(), CHATGPT_GPT_LIVE_CALL_URL);
    assert_eq!(request.headers()["Content-Type"], "application/json");
    assert_eq!(request.headers()["originator"], "arco");
    assert_eq!(request.headers().len(), 10);
    assert!(!request.headers().contains_key("x-arco-feature"));
    assert_eq!(GPT_LIVE_FEATURE_LABEL, "Beta");
    let body: serde_json::Value = serde_json::from_slice(request.body()).unwrap();
    assert_eq!(body["sdp"], "v=0\r\no=offer\r\n");
    assert_eq!(body["session"]["model"], "gpt-live-1-codex");
    assert_eq!(body["session"]["audio"]["output"]["voice"], "spruce");
    assert_eq!(
        response,
        GptLiveCallResponse {
            status: 201,
            answer_sdp: "v=0\r\no=answer\r\n".into(),
            call_id: "rtc_call-123".into(),
            sideband_url: "wss://api.openai.com/v1/live/rtc_call-123".into(),
        }
    );
    let debug = format!("{request:?}");
    assert!(!debug.contains("secret-access"));
    assert!(!debug.contains("acct-123"));
}

#[test]
fn invalid_or_oversized_offers_fail_before_network_io() {
    let auth = GptLiveAuth::oauth("secret-access", "acct-123").unwrap();
    let session = GptLiveSession::new("Answer briefly.", None, vec![]).unwrap();
    let transport = transport(RawGptLiveCallResponse {
        status: 201,
        location: Some("/v1/live/rtc_unused".into()),
        openai_session_id: None,
        body: b"v=0\r\n".to_vec(),
    });

    assert_eq!(
        create_call_with_transport(&transport, &auth, &ids(), "", &session).unwrap_err(),
        "GPT-Live SDP offer is empty"
    );
    assert_eq!(
        create_call_with_transport(
            &transport,
            &auth,
            &ids(),
            &format!("v=0\r\n{}", "x".repeat(256 * 1024)),
            &session,
        )
        .unwrap_err(),
        "GPT-Live SDP offer is too large"
    );
    assert_eq!(transport.calls.get(), 0);
}

#[test]
fn provider_failures_are_bounded_and_redacted() {
    let auth = GptLiveAuth::oauth("secret-access", "acct-123").unwrap();
    let session = GptLiveSession::new("Answer briefly.", None, vec![]).unwrap();
    let transport = transport(RawGptLiveCallResponse {
        status: 403,
        location: None,
        openai_session_id: None,
        body: format!(
            "denied Bearer secret-access account=acct-123 {}",
            "untrusted ".repeat(1_000)
        )
        .into_bytes(),
    });

    let error =
        create_call_with_transport(&transport, &auth, &ids(), "v=0\r\no=offer\r\n", &session)
            .unwrap_err();

    assert!(error.starts_with("GPT-Live rejected the session (403)"));
    assert!(error.len() <= 600);
    assert!(!error.contains("secret-access"));
    assert!(!error.contains("acct-123"));
}

#[test]
fn successful_response_requires_a_small_utf8_sdp_and_valid_call_id() {
    let auth = GptLiveAuth::oauth("secret-access", "acct-123").unwrap();
    let session = GptLiveSession::new("Answer briefly.", None, vec![]).unwrap();

    for response in [
        RawGptLiveCallResponse {
            status: 201,
            location: Some("/v1/live/rtc_ok".into()),
            openai_session_id: None,
            body: Vec::new(),
        },
        RawGptLiveCallResponse {
            status: 201,
            location: Some("/v1/live/rtc_ok".into()),
            openai_session_id: None,
            body: vec![0xff, 0xfe],
        },
        RawGptLiveCallResponse {
            status: 201,
            location: Some("https://example.test/v1/live/rtc_bad".into()),
            openai_session_id: None,
            body: b"v=0\r\n".to_vec(),
        },
    ] {
        let transport = transport(response);
        assert!(create_call_with_transport(
            &transport,
            &auth,
            &ids(),
            "v=0\r\no=offer\r\n",
            &session,
        )
        .is_err());
    }
}
