use arco_core::gpt_live::{
    auth_headers, bound_delegation_result, bound_initial_items, build_sideband_url,
    build_speakable_events, extract_call_id, parse_inbound_event, redact_provider_error,
    GptLiveAuth, GptLiveInboundEvent, GptLiveRole, GptLiveSession, InitialItem, RequestIds,
    CHATGPT_GPT_LIVE_CALL_URL, GPT_LIVE_MODEL, GPT_LIVE_VOICE,
};

fn item(role: GptLiveRole, text: impl Into<String>) -> InitialItem {
    InitialItem {
        role,
        text: text.into(),
    }
}

#[test]
fn session_uses_the_codex_live_model_voice_and_client_delegation() {
    let session = GptLiveSession::new(
        "  Keep answers short.  ",
        None,
        vec![
            item(GptLiveRole::User, "What did we decide?"),
            item(GptLiveRole::Assistant, "I will check."),
        ],
    )
    .unwrap();

    let json = serde_json::to_value(session).unwrap();
    assert_eq!(json["model"], GPT_LIVE_MODEL);
    assert_eq!(json["instructions"], "Keep answers short.");
    assert_eq!(json["audio"]["output"]["voice"], GPT_LIVE_VOICE);
    assert_eq!(json["delegation"]["type"], "client");
    assert_eq!(json["initial_items"][0]["role"], "user");
    assert_eq!(json["initial_items"][0]["content"][0]["type"], "input_text");
    assert_eq!(json["initial_items"][1]["role"], "assistant");
    assert_eq!(
        json["initial_items"][1]["content"][0]["type"],
        "output_text"
    );
}

#[test]
fn initial_items_keep_only_the_latest_sixteen_entries() {
    let items = (0..20)
        .map(|index| item(GptLiveRole::User, format!("item-{index}")))
        .collect::<Vec<_>>();

    let bounded = bound_initial_items(&items);

    assert_eq!(bounded.len(), 16);
    assert_eq!(bounded.first().unwrap().text, "item-4");
    assert_eq!(bounded.last().unwrap().text, "item-19");
}

#[test]
fn initial_items_enforce_character_and_utf8_byte_limits_without_splitting_emoji() {
    let items = (0..16)
        .map(|_| item(GptLiveRole::User, "会🙂".repeat(900)))
        .collect::<Vec<_>>();

    let bounded = bound_initial_items(&items);
    let total_bytes = bounded.iter().map(|entry| entry.text.len()).sum::<usize>();

    assert!(bounded
        .iter()
        .all(|entry| entry.text.chars().count() <= 800));
    assert!(total_bytes <= 8_000);
    assert!(bounded
        .iter()
        .all(|entry| !entry.text.ends_with('\u{fffd}')));
    assert_eq!(bounded.last().unwrap().text.chars().count(), 800);
}

#[test]
fn delegation_event_joins_only_input_text_parts() {
    let payload = serde_json::json!({
        "type": "delegation.created",
        "item": {
            "id": "delegation_123",
            "type": "delegation",
            "target": "client",
            "content": [
                { "type": "input_text", "text": "check " },
                { "type": "image", "text": "do not include" },
                { "type": "input_text", "text": "the repository" }
            ]
        }
    });

    assert_eq!(
        parse_inbound_event(&payload.to_string()),
        Some(GptLiveInboundEvent::Delegation {
            id: "delegation_123".into(),
            prompt: "check the repository".into(),
        })
    );
}

#[test]
fn malformed_or_non_client_delegation_is_ignored_instead_of_executed() {
    let wrong_target = serde_json::json!({
        "type": "delegation.created",
        "item": {
            "id": "delegation_123",
            "type": "delegation",
            "target": "server",
            "content": [{ "type": "input_text", "text": "run a command" }]
        }
    });
    let missing_id = serde_json::json!({
        "type": "delegation.created",
        "item": {
            "type": "delegation",
            "target": "client",
            "content": [{ "type": "input_text", "text": "run a command" }]
        }
    });

    assert_eq!(
        parse_inbound_event(&wrong_target.to_string()),
        Some(GptLiveInboundEvent::Ignored {
            event_type: "delegation.created".into(),
        })
    );
    assert_eq!(
        parse_inbound_event(&missing_id.to_string()),
        Some(GptLiveInboundEvent::Ignored {
            event_type: "delegation.created".into(),
        })
    );
    assert_eq!(parse_inbound_event("not json"), None);
}

#[test]
fn known_transcript_turn_audio_and_auth_error_events_are_typed() {
    assert_eq!(
        parse_inbound_event(r#"{"type":"session.started","session":{"expires_at":1234}}"#),
        Some(GptLiveInboundEvent::SessionStarted {
            expires_at: Some(1234),
        })
    );
    assert_eq!(
        parse_inbound_event(r#"{"type":"input_transcript.added","item":{"text":"hello"}}"#),
        Some(GptLiveInboundEvent::TranscriptDelta {
            role: GptLiveRole::User,
            text: "hello".into(),
        })
    );
    assert_eq!(
        parse_inbound_event(
            r#"{"type":"turn.done","turn":{"role":"assistant","transcript":"done"}}"#
        ),
        Some(GptLiveInboundEvent::TranscriptDone {
            role: GptLiveRole::Assistant,
            text: "done".into(),
        })
    );
    assert_eq!(
        parse_inbound_event(r#"{"type":"output_audio.delta","audio":"AQID"}"#),
        Some(GptLiveInboundEvent::Audio {
            base64_data: "AQID".into(),
        })
    );
    assert_eq!(
        parse_inbound_event(
            r#"{"type":"error","error":{"status":401,"code":"token_expired","message":"expired"}}"#
        ),
        Some(GptLiveInboundEvent::Error {
            message: "expired".into(),
            fatal_auth: true,
        })
    );
}

#[test]
fn speakable_results_are_bounded_and_split_on_utf8_boundaries() {
    let text = "答🙂".repeat(1_200);
    let bounded = bound_delegation_result(&text);
    let events = build_speakable_events("delegation_123", &bounded).unwrap();

    assert!(bounded.chars().count() <= 1_800);
    assert!(bounded.ends_with(" [truncated]"));
    assert!(events.len() > 1);
    for event in &events {
        let chunk = event["content"][0]["text"].as_str().unwrap();
        assert!(chunk.len() <= 500);
        assert_eq!(event["type"], "delegation.context.append");
        assert_eq!(event["delegation_item_id"], "delegation_123");
        assert_eq!(event["channel"], "speakable");
    }
    let reconstructed = events
        .iter()
        .map(|event| event["content"][0]["text"].as_str().unwrap())
        .collect::<String>();
    assert_eq!(reconstructed, bounded);
}

#[test]
fn invalid_delegation_ids_cannot_be_written_to_sideband() {
    let error = build_speakable_events("bad/id", "result").unwrap_err();
    assert_eq!(error, "GPT-Live delegation id is invalid");
}

#[test]
fn call_id_is_extracted_from_location_or_valid_session_header() {
    assert_eq!(
        extract_call_id(
            Some("https://chatgpt.com/backend-api/codex/realtime/calls/rtc_call-123"),
            None,
        )
        .unwrap(),
        "rtc_call-123"
    );
    assert_eq!(
        extract_call_id(None, Some("123e4567-e89b-12d3-a456-426614174000")).unwrap(),
        "123e4567-e89b-12d3-a456-426614174000"
    );
    assert_eq!(
        build_sideband_url("rtc_call-123").unwrap(),
        "wss://api.openai.com/v1/live/rtc_call-123"
    );
}

#[test]
fn oversized_or_injected_call_ids_are_rejected() {
    assert!(extract_call_id(Some(&"x".repeat(513)), None).is_err());
    assert!(extract_call_id(Some("https://example.test/path/bad.id"), None).is_err());
    assert!(extract_call_id(None, Some("../escape")).is_err());
    assert!(build_sideband_url("rtc_ok?redirect=evil").is_err());
}

#[test]
fn oauth_headers_are_exact_and_debug_output_never_contains_credentials() {
    let auth = GptLiveAuth::oauth("secret-access-token", "account-secret").unwrap();
    let ids = RequestIds {
        realtime_session_id: "realtime-1".into(),
        session_id: "session-1".into(),
        thread_id: "thread-1".into(),
    };

    let headers = auth_headers(&auth, &ids).unwrap();

    assert_eq!(
        CHATGPT_GPT_LIVE_CALL_URL,
        "https://chatgpt.com/backend-api/codex/realtime/calls?intent=quicksilver&architecture=avas"
    );
    assert_eq!(
        headers.get("Authorization").unwrap(),
        "Bearer secret-access-token"
    );
    assert_eq!(headers.get("chatgpt-account-id").unwrap(), "account-secret");
    assert_eq!(headers.get("OpenAI-Alpha").unwrap(), "quicksilver=v2");
    assert_eq!(headers.get("x-session-id").unwrap(), "realtime-1");
    assert_eq!(headers.get("session-id").unwrap(), "session-1");
    assert_eq!(headers.get("thread-id").unwrap(), "thread-1");

    let debug = format!("{auth:?}");
    assert!(!debug.contains("secret-access-token"));
    assert!(!debug.contains("account-secret"));
    assert!(debug.contains("REDACTED"));
}

#[test]
fn credentials_and_bearer_values_are_removed_from_provider_errors() {
    let auth = GptLiveAuth::oauth("secret-access-token", "account-secret").unwrap();
    let raw = "request failed: Bearer secret-access-token account=account-secret token=abc123";
    let redacted = redact_provider_error(raw, &auth);

    assert!(!redacted.contains("secret-access-token"));
    assert!(!redacted.contains("account-secret"));
    assert!(!redacted.contains("abc123"));
    assert_eq!(
        redacted,
        "request failed: Bearer [REDACTED] account=[REDACTED] token=[REDACTED]"
    );
}

#[test]
fn empty_or_whitespace_credentials_are_rejected() {
    assert_eq!(
        GptLiveAuth::oauth("", "account").unwrap_err(),
        "GPT-Live OAuth token is missing"
    );
    assert_eq!(
        GptLiveAuth::oauth("token", "has space").unwrap_err(),
        "GPT-Live account id contains invalid characters"
    );
}
