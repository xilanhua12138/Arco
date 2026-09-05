use std::collections::BTreeMap;

use arco_gpt_live::{
    GptLiveMeetingContext, GptLiveRuntimeCommand, GptLiveSessionOptions, LIVE_BETA_ACK,
    build_sideband_request, callback_url_from_http_request, finish_live_handshake,
    parse_runtime_command, require_beta_ack, resolve_https_proxy_from,
};

#[test]
fn a_live_subscription_probe_requires_the_exact_beta_acknowledgement() {
    assert!(require_beta_ack(Some(LIVE_BETA_ACK)).is_ok());
    for value in [None, Some(""), Some("yes"), Some("I understand")] {
        assert_eq!(
            require_beta_ack(value).unwrap_err(),
            format!("live GPT-Live probing requires --ack {LIVE_BETA_ACK}")
        );
    }
}

#[test]
fn product_session_arguments_require_an_exact_beta_ack_recorder_and_audio_mode() {
    let args = [
        "--ack",
        LIVE_BETA_ACK,
        "--recorder",
        "/Applications/Arco.app/Contents/Resources/native/recorder",
        "--mode",
        "both",
        "--transcript",
        "/tmp/transcript-20260903-211826.md",
        "--provider",
        "codex",
    ]
    .map(str::to_string);
    let parsed = GptLiveSessionOptions::parse(&args).unwrap();

    assert_eq!(
        parsed.recorder.to_string_lossy(),
        "/Applications/Arco.app/Contents/Resources/native/recorder"
    );
    assert_eq!(parsed.mode, "both");
    assert_eq!(
        parsed.transcript.to_string_lossy(),
        "/tmp/transcript-20260903-211826.md"
    );
    assert_eq!(parsed.provider, "codex");

    for invalid in [
        vec![
            "--ack",
            "wrong",
            "--recorder",
            "/tmp/recorder",
            "--mode",
            "both",
        ],
        vec!["--ack", LIVE_BETA_ACK, "--mode", "both"],
        vec![
            "--ack",
            LIVE_BETA_ACK,
            "--recorder",
            "/tmp/recorder",
            "--mode",
            "camera",
        ],
        vec![
            "--ack",
            LIVE_BETA_ACK,
            "--recorder",
            "relative",
            "--mode",
            "mic",
        ],
        vec![
            "--ack",
            LIVE_BETA_ACK,
            "--recorder",
            "/tmp/a",
            "--recorder",
            "/tmp/b",
            "--mode",
            "mic",
        ],
        vec![
            "--ack",
            LIVE_BETA_ACK,
            "--recorder",
            "/tmp/recorder",
            "--mode",
            "both",
            "--transcript",
            "relative.md",
            "--provider",
            "codex",
        ],
        vec![
            "--ack",
            LIVE_BETA_ACK,
            "--recorder",
            "/tmp/recorder",
            "--mode",
            "both",
            "--transcript",
            "/tmp/meeting.md",
            "--provider",
            "unknown",
        ],
    ] {
        let invalid = invalid.into_iter().map(str::to_string).collect::<Vec<_>>();
        assert!(
            GptLiveSessionOptions::parse(&invalid).is_err(),
            "accepted {invalid:?}"
        );
    }
}

#[test]
fn product_runtime_exposes_only_acknowledged_session_and_oauth_commands() {
    for command in ["auth-status", "login", "logout"] {
        let args = [command, "--ack", LIVE_BETA_ACK].map(str::to_string);
        let parsed = parse_runtime_command(&args).unwrap();
        assert_eq!(
            parsed,
            match command {
                "auth-status" => GptLiveRuntimeCommand::AuthStatus,
                "login" => GptLiveRuntimeCommand::Login,
                "logout" => GptLiveRuntimeCommand::Logout,
                _ => unreachable!(),
            }
        );
    }

    for args in [
        vec!["login"],
        vec!["login", "--ack", "wrong"],
        vec!["logout", "--ack", LIVE_BETA_ACK, "extra"],
        vec!["unknown", "--ack", LIVE_BETA_ACK],
    ] {
        let args = args.into_iter().map(str::to_string).collect::<Vec<_>>();
        assert!(parse_runtime_command(&args).is_err(), "accepted {args:?}");
    }
}

#[test]
fn meeting_delegation_reloads_the_current_transcript_for_each_question() {
    let directory = tempfile::tempdir().unwrap();
    let transcript = directory.path().join("meeting.md");
    std::fs::write(
        &transcript,
        "# Meeting Transcript\n\n> Started: 2026-09-03 21:18:26 (recording)\n\n**[21:18:46] In room 1:** 我们正在讨论 Beta 发布。\n",
    )
    .unwrap();
    let context = GptLiveMeetingContext::new(transcript.clone(), "codex").unwrap();

    let first = context
        .answer_with(
            "delegation_1",
            "目前聊到哪里了？",
            |provider, prompt, meeting| {
                assert_eq!(provider, "codex");
                assert_eq!(prompt, "目前聊到哪里了？");
                assert!(meeting.raw_markdown.contains("Beta 发布"));
                Ok("正在讨论 Beta 发布。".into())
            },
        )
        .unwrap();
    assert_eq!(first[0]["content"][0]["text"], "正在讨论 Beta 发布。");

    std::fs::write(
        &transcript,
        "# Meeting Transcript\n\n> Started: 2026-09-03 21:18:26 (recording)\n\n**[21:19:46] Remote 1:** 现在转到发布时间。\n",
    )
    .unwrap();
    context
        .answer_with("delegation_2", "最新进度呢？", |_, _, meeting| {
            assert!(meeting.raw_markdown.contains("发布时间"));
            assert!(!meeting.raw_markdown.contains("Beta 发布"));
            Ok("现在在确定发布时间。".into())
        })
        .unwrap();
}

#[test]
fn meeting_delegation_includes_live_snapshot_lines_before_markdown_finalization() {
    let directory = tempfile::tempdir().unwrap();
    let transcript = directory.path().join("meeting.md");
    std::fs::write(
        &transcript,
        "# Meeting Transcript\n\n> Started: 2026-09-03 21:18:26 (recording)\n",
    )
    .unwrap();
    std::fs::write(
        format!("{}.live.json", transcript.display()),
        r#"{"lines":[{"id":"live-1","timestamp":"21:18:46","speaker":"Remote 1","text":"正在验证实时会议进度。"}]}"#,
    )
    .unwrap();
    let context = GptLiveMeetingContext::new(transcript, "codex").unwrap();

    let events = context
        .answer_with(
            "delegation_live",
            "现在聊到哪里？",
            |_, _, meeting| {
                assert_eq!(meeting.lines.len(), 1);
                assert!(meeting.raw_markdown.contains("正在验证实时会议进度。"));
                Ok("正在验证实时会议进度。".into())
            },
        )
        .unwrap();

    assert_eq!(events[0]["content"][0]["text"], "正在验证实时会议进度。");
}

#[test]
fn meeting_delegation_returns_speakable_failures_for_empty_or_failed_queries() {
    let directory = tempfile::tempdir().unwrap();
    let transcript = directory.path().join("meeting.md");
    std::fs::write(
        &transcript,
        "# Meeting Transcript\n\n> Started: 2026-09-03 21:18:26 (recording)\n",
    )
    .unwrap();
    let context = GptLiveMeetingContext::new(transcript.clone(), "codex").unwrap();
    let empty = context
        .answer_with("delegation_empty", "聊到哪了？", |_, _, _| {
            panic!("an empty transcript must not launch the agent")
        })
        .unwrap();
    assert!(
        empty[0]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("transcript is still empty")
    );

    std::fs::write(
        &transcript,
        "# Meeting Transcript\n\n> Started: 2026-09-03 21:18:26 (recording)\n\n**[21:18:46] In room 1:** 有内容。\n",
    )
    .unwrap();
    let failed = context
        .answer_with("delegation_failed", "总结一下", |_, _, _| {
            Err("private provider detail".into())
        })
        .unwrap();
    let text = failed[0]["content"][0]["text"].as_str().unwrap();
    assert!(text.contains("agent task failed"));
    assert!(!text.contains("private provider detail"));
}

#[test]
fn sideband_request_accepts_only_the_fixed_openai_target_and_exact_auth_headers() {
    let headers = BTreeMap::from([
        ("Authorization".into(), "Bearer secret-access".into()),
        ("OpenAI-Alpha".into(), "quicksilver=v2".into()),
        ("chatgpt-account-id".into(), "acct-123".into()),
        ("session-id".into(), "session-123".into()),
        ("thread-id".into(), "thread-123".into()),
        ("x-session-id".into(), "realtime-123".into()),
        ("User-Agent".into(), "arco/0.3.17".into()),
        ("originator".into(), "arco".into()),
        ("version".into(), "0.3.17".into()),
    ]);

    let request =
        build_sideband_request("wss://api.openai.com/v1/live/rtc_call-123", &headers).unwrap();

    assert_eq!(
        request.uri().to_string(),
        "wss://api.openai.com/v1/live/rtc_call-123"
    );
    for (name, value) in headers {
        assert_eq!(request.headers()[name], value);
    }
    for url in [
        "ws://api.openai.com/v1/live/rtc_call-123",
        "wss://example.test/v1/live/rtc_call-123",
        "wss://api.openai.com/v1/live/../../other",
        "wss://api.openai.com/v1/live/rtc_call-123?token=secret",
    ] {
        assert!(build_sideband_request(url, &BTreeMap::new()).is_err());
    }
}

#[test]
fn oauth_callback_http_parser_accepts_only_the_expected_get_request() {
    assert_eq!(
        callback_url_from_http_request(
            b"GET /auth/callback?code=secret-code&state=state-123 HTTP/1.1\r\nHost: 127.0.0.1:1455\r\n\r\n"
        )
        .unwrap(),
        "http://localhost:1455/auth/callback?code=secret-code&state=state-123"
    );
    for request in [
        b"POST /auth/callback?code=a&state=b HTTP/1.1\r\n\r\n".as_slice(),
        b"GET /other?code=a&state=b HTTP/1.1\r\n\r\n".as_slice(),
        b"GET https://attacker.test/auth/callback?code=a HTTP/1.1\r\n\r\n".as_slice(),
        b"not http".as_slice(),
    ] {
        assert!(callback_url_from_http_request(request).is_err());
    }
    assert!(callback_url_from_http_request(&vec![b'x'; 16 * 1024 + 1]).is_err());
}

#[test]
fn sideband_proxy_resolution_prefers_https_proxy_and_honors_no_proxy() {
    let variables = BTreeMap::from([
        ("HTTPS_PROXY".into(), "http://127.0.0.1:7890".into()),
        ("HTTP_PROXY".into(), "http://wrong.example:8080".into()),
        ("ALL_PROXY".into(), "http://also-wrong.example:8081".into()),
    ]);

    let proxy = resolve_https_proxy_from(&variables, "api.openai.com")
        .unwrap()
        .unwrap();
    assert_eq!(proxy.host(), "127.0.0.1");
    assert_eq!(proxy.port(), 7890);
    assert!(!proxy.has_credentials());

    let mut bypassed = variables.clone();
    bypassed.insert("NO_PROXY".into(), ".openai.com,localhost".into());
    assert!(
        resolve_https_proxy_from(&bypassed, "api.openai.com")
            .unwrap()
            .is_none()
    );
}

#[test]
fn sideband_proxy_resolution_rejects_unsupported_or_unsafe_proxy_urls() {
    for proxy_url in [
        "socks5://127.0.0.1:7890",
        "https://127.0.0.1:7890",
        "http://127.0.0.1:7890/path",
        "http://127.0.0.1:7890?secret=value",
    ] {
        let variables = BTreeMap::from([("HTTPS_PROXY".into(), proxy_url.into())]);
        assert!(resolve_https_proxy_from(&variables, "api.openai.com").is_err());
    }
}

#[tokio::test]
async fn live_handshake_attaches_sideband_before_waiting_for_media() {
    let observed = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let sideband_observed = observed.clone();
    let media_observed = observed.clone();

    finish_live_handshake(
        async move {
            sideband_observed.lock().unwrap().push("sideband");
            Ok(())
        },
        async move {
            media_observed.lock().unwrap().push("media");
            Ok(())
        },
    )
    .await
    .unwrap();

    assert_eq!(*observed.lock().unwrap(), ["sideband", "media"]);
}

#[tokio::test]
async fn live_handshake_polls_sideband_and_media_concurrently() {
    let media_started = std::sync::Arc::new(tokio::sync::Notify::new());
    let sideband_wait = media_started.clone();
    let media_signal = media_started.clone();

    tokio::time::timeout(
        std::time::Duration::from_millis(100),
        finish_live_handshake(
            async move {
                sideband_wait.notified().await;
                Ok(())
            },
            async move {
                media_signal.notify_one();
                Ok(())
            },
        ),
    )
    .await
    .expect("media setup must be polled while sideband startup is waiting")
    .unwrap();
}
