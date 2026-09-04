use std::env;
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use arco_core::gpt_live::{
    GptLiveAuth, GptLiveInboundEvent, GptLiveRole, GptLiveSession, RequestIds,
    UreqGptLiveCallTransport, create_call_with_transport, parse_inbound_event,
    sideband_auth_headers,
};
use arco_core::gpt_live_oauth::{
    GptLiveCredentialStorage, GptLiveCredentials, MacOSGptLiveCredentialStorage,
    OPENAI_OAUTH_CALLBACK_HOST, TokenResult, UreqOAuthTokenTransport,
    create_default_authorization_flow, exchange_token_with_transport, extract_auth_identity,
    load_credentials_from, parse_callback_url, refresh_token_with_transport, save_credentials_to,
};
use arco_gpt_live::{
    GptLiveWebRtcPeer, LIVE_BETA_ACK, OPUS_FRAME_SAMPLES_PER_CHANNEL, SpeechEnergyGate,
    TranscriptMarkerGate, build_sideband_request, callback_url_from_http_request,
    finish_live_handshake, require_beta_ack, resolve_https_proxy,
};
use async_http_proxy::{http_connect_tokio, http_connect_tokio_with_basic_auth};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::protocol::{Message, WebSocketConfig};

const CALLBACK_WAIT: Duration = Duration::from_secs(180);
const NETWORK_WAIT: Duration = Duration::from_secs(15);
const LIVE_PROBE_MARKER: &str = "Arco GPT Live transport test OK";

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("GPT Live Beta probe failed: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    match args.first().map(String::as_str) {
        Some("media") if args.len() == 1 => run_media_probe().await,
        Some("login") if args.len() == 1 => run_login().await,
        Some("status") if args.len() == 1 => show_status(),
        Some("logout") if args.len() == 1 => logout(),
        Some("live") => {
            let ack = args
                .windows(2)
                .find(|pair| pair[0] == "--ack")
                .map(|pair| pair[1].as_str());
            require_beta_ack(ack)?;
            run_live_handshake().await
        }
        _ => Err(format!(
            "usage:\n  arco-gpt-live-probe media\n  arco-gpt-live-probe login\n  arco-gpt-live-probe status\n  arco-gpt-live-probe logout\n  arco-gpt-live-probe live --ack {LIVE_BETA_ACK}"
        )),
    }
}

async fn run_media_probe() -> Result<(), String> {
    let caller = GptLiveWebRtcPeer::new().await?;
    let callee = GptLiveWebRtcPeer::new().await?;
    let result: Result<(), String> = async {
        let offer = caller.create_offer(Duration::from_secs(5)).await?;
        let answer = callee.answer_offer(&offer, Duration::from_secs(5)).await?;
        caller.apply_answer(&answer).await?;
        caller.wait_connected(Duration::from_secs(10)).await?;
        callee.wait_connected(Duration::from_secs(10)).await?;
        let mut input = vec![0_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];
        for (index, stereo_sample) in input.chunks_exact_mut(2).enumerate() {
            let sample = (((index % 64) as i16) - 32) * 500;
            stereo_sample[0] = sample;
            stereo_sample[1] = -sample;
        }
        caller.send_20ms_stereo(&input).await?;
        let decoded = callee
            .receive_decoded_stereo(Duration::from_secs(5))
            .await?;
        if decoded.len() != OPUS_FRAME_SAMPLES_PER_CHANNEL * 2
            || !decoded.iter().any(|sample| sample.unsigned_abs() > 100)
        {
            return Err("local WebRTC/Opus probe returned invalid audio".into());
        }
        Ok(())
    }
    .await;
    let caller_close = caller.close().await;
    let callee_close = callee.close().await;
    result?;
    caller_close?;
    callee_close?;
    println!("GPT Live Beta local WebRTC/Opus probe passed.");
    Ok(())
}

async fn run_login() -> Result<(), String> {
    let flow = create_default_authorization_flow()?;
    let listener = TcpListener::bind((OPENAI_OAUTH_CALLBACK_HOST, 1455))
        .await
        .map_err(|error| format!("could not open the OAuth callback listener: {error}"))?;
    println!("Opening the OpenAI sign-in page for Arco GPT Live Beta…");
    println!(
        "If the browser does not open, visit:\n{}",
        flow.authorization_url
    );
    let status = Command::new("open")
        .arg(&flow.authorization_url)
        .status()
        .map_err(|error| format!("could not open the sign-in page: {error}"))?;
    if !status.success() {
        return Err("macOS could not open the OpenAI sign-in page".into());
    }
    let code = wait_for_oauth_code(listener, &flow.state).await?;
    let token = exchange_token_with_transport(
        &UreqOAuthTokenTransport::default(),
        &code,
        &flow.verifier,
        &flow.redirect_uri,
        now_ms()?,
    );
    let credentials = credentials_from_login_result(token)?;
    save_credentials_to(&MacOSGptLiveCredentialStorage, &credentials)?;
    let identity = credentials
        .email()
        .unwrap_or_else(|| credentials.account_id());
    println!("OpenAI sign-in saved in macOS Keychain for {identity}.");
    println!(
        "This only enables the Beta credential; GPT Live remains controlled by Arco's Beta toggle."
    );
    Ok(())
}

async fn wait_for_oauth_code(
    listener: TcpListener,
    expected_state: &str,
) -> Result<String, String> {
    tokio::time::timeout(CALLBACK_WAIT, async {
        loop {
            let (mut stream, peer) = listener
                .accept()
                .await
                .map_err(|error| format!("could not accept the OAuth callback: {error}"))?;
            if !peer.ip().is_loopback() {
                let _ = reply_to_browser(&mut stream, false).await;
                continue;
            }
            let result = read_oauth_code(&mut stream, expected_state).await;
            let _ = reply_to_browser(&mut stream, result.is_ok()).await;
            match result {
                Ok(code) => return Ok(code),
                Err(error)
                    if error == "OpenAI OAuth login was cancelled or denied"
                        || error == "OpenAI OAuth provider returned an error" =>
                {
                    return Err(error);
                }
                Err(_) => {}
            }
        }
    })
    .await
    .map_err(|_| "OpenAI sign-in timed out".to_string())?
}

async fn read_oauth_code(stream: &mut TcpStream, expected_state: &str) -> Result<String, String> {
    let mut request = Vec::new();
    loop {
        let mut chunk = [0_u8; 2_048];
        let count = tokio::time::timeout(Duration::from_secs(5), stream.read(&mut chunk))
            .await
            .map_err(|_| "OpenAI OAuth callback read timed out".to_string())?
            .map_err(|error| format!("could not read the OAuth callback: {error}"))?;
        if count == 0 {
            break;
        }
        request.extend_from_slice(&chunk[..count]);
        if request.len() > 16 * 1024 {
            return Err("OpenAI OAuth callback request is too large".into());
        }
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    let callback_url = callback_url_from_http_request(&request)?;
    parse_callback_url(&callback_url, expected_state)
}

async fn reply_to_browser(stream: &mut TcpStream, success: bool) -> Result<(), String> {
    let (status, message) = if success {
        (
            "200 OK",
            "Arco GPT Live Beta sign-in is complete. You can close this tab.",
        )
    } else {
        (
            "400 Bad Request",
            "Arco could not accept this sign-in callback. Return to Arco and try again.",
        )
    };
    let body = format!(
        "<!doctype html><meta charset=\"utf-8\"><title>Arco GPT Live Beta</title><p>{message}</p>"
    );
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .await
        .map_err(|error| format!("could not reply to the OAuth callback: {error}"))
}

fn credentials_from_login_result(result: TokenResult) -> Result<GptLiveCredentials, String> {
    match result {
        TokenResult::Success {
            access_token,
            refresh_token,
            expires_at_ms,
        } => {
            let identity = extract_auth_identity(&access_token)?;
            GptLiveCredentials::new(
                &access_token,
                &refresh_token,
                &identity.account_id,
                expires_at_ms,
                identity.email,
                identity.plan_type,
            )
        }
        TokenResult::Failed(failure) => Err(failure.summary),
    }
}

fn show_status() -> Result<(), String> {
    let Some(credentials) = load_credentials_from(&MacOSGptLiveCredentialStorage)? else {
        println!("GPT Live Beta: not signed in.");
        return Ok(());
    };
    let status = credentials.status(now_ms()?);
    let identity = status
        .email
        .as_deref()
        .or(status.account_id.as_deref())
        .unwrap_or("unknown account");
    println!(
        "GPT Live Beta: signed in as {identity}; token {}.",
        if status.valid {
            "is valid"
        } else {
            "needs refresh"
        }
    );
    Ok(())
}

fn logout() -> Result<(), String> {
    MacOSGptLiveCredentialStorage.delete()?;
    println!("GPT Live Beta OpenAI sign-in was removed from macOS Keychain.");
    Ok(())
}

async fn run_live_handshake() -> Result<(), String> {
    let storage = MacOSGptLiveCredentialStorage;
    let credentials = load_credentials_from(&storage)?
        .ok_or_else(|| "run `arco-gpt-live-probe login` first".to_string())?;
    let credentials = refresh_if_needed(credentials)?;
    save_credentials_to(&storage, &credentials)?;

    let auth = GptLiveAuth::oauth(credentials.access_token(), credentials.account_id())?;
    let request_ids = RequestIds::new();
    let session = GptLiveSession::new(
        &format!("This is an Arco GPT-Live transport check. Immediately say: {LIVE_PROBE_MARKER}."),
        None,
        vec![],
    )?;
    let peer = GptLiveWebRtcPeer::new().await?;
    let result: Result<(), String> = async {
        println!("GPT Live Beta probe: creating the WebRTC offer…");
        let offer = peer.create_offer(Duration::from_secs(5)).await?;
        println!("GPT Live Beta probe: creating the subscription call…");
        let call = create_call_with_transport(
            &UreqGptLiveCallTransport::default(),
            &auth,
            &request_ids,
            &offer,
            &session,
        )?;
        println!("GPT Live Beta probe: applying the SDP answer…");
        peer.apply_answer(&call.answer_sdp).await?;
        let (audio_verified_tx, audio_verified_rx) = tokio::sync::watch::channel(false);
        finish_live_handshake(
            wait_for_sideband_start(&call.sideband_url, &auth, &request_ids, audio_verified_rx),
            async {
                prime_probe_media(&peer).await?;
                audio_verified_tx.send_replace(true);
                Ok(())
            },
        )
        .await?;
        println!(
            "GPT Live Beta subscription voice proof passed for model gpt-live-1-codex (call {}).",
            call.call_id
        );
        Ok(())
    }
    .await;
    let close = peer.close().await;
    result?;
    close
}

async fn prime_probe_media(peer: &GptLiveWebRtcPeer) -> Result<(), String> {
    println!("GPT Live Beta probe: waiting for WebRTC media…");
    peer.wait_connected(NETWORK_WAIT).await?;
    println!("GPT Live Beta probe: WebRTC connected; waiting for audible model speech…");
    let silence = vec![0_i16; OPUS_FRAME_SAMPLES_PER_CHANNEL * 2];
    let sender = async {
        let deadline = tokio::time::Instant::now() + NETWORK_WAIT;
        let mut interval = tokio::time::interval(Duration::from_millis(20));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        while tokio::time::Instant::now() < deadline {
            interval.tick().await;
            peer.send_20ms_stereo(&silence).await?;
        }
        Err::<(), String>("GPT-Live audible speech proof timed out".into())
    };
    let receiver = async {
        let mut gate = SpeechEnergyGate::gpt_live_smoke();
        loop {
            let decoded = peer.receive_decoded_stereo(NETWORK_WAIT).await?;
            if gate.observe_stereo(&decoded)? {
                return Ok(());
            }
        }
    };
    tokio::select! {
        result = sender => result,
        result = receiver => result,
    }
}

fn refresh_if_needed(credentials: GptLiveCredentials) -> Result<GptLiveCredentials, String> {
    let now = now_ms()?;
    if credentials.expires_at_ms() > now.saturating_add(60_000) {
        return Ok(credentials);
    }
    match refresh_token_with_transport(
        &UreqOAuthTokenTransport::default(),
        credentials.refresh_token(),
        now,
    ) {
        TokenResult::Success {
            access_token,
            refresh_token,
            expires_at_ms,
        } => GptLiveCredentials::new(
            &access_token,
            &refresh_token,
            credentials.account_id(),
            expires_at_ms,
            credentials.email().map(str::to_string),
            credentials.plan_type().map(str::to_string),
        ),
        TokenResult::Failed(failure) => Err(failure.summary),
    }
}

async fn wait_for_sideband_start(
    sideband_url: &str,
    auth: &GptLiveAuth,
    request_ids: &RequestIds,
    mut audio_verified: tokio::sync::watch::Receiver<bool>,
) -> Result<(), String> {
    let request = build_sideband_request(sideband_url, &sideband_auth_headers(auth, request_ids)?)?;
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(16 * 1024 * 1024);
    config.max_frame_size = Some(16 * 1024 * 1024);
    let connect = async {
        if let Some(proxy) = resolve_https_proxy("api.openai.com")? {
            let mut stream = TcpStream::connect((proxy.host(), proxy.port()))
                .await
                .map_err(|error| {
                    format!("GPT-Live could not connect to the configured proxy: {error}")
                })?;
            if let Some((username, password)) = proxy.credentials() {
                http_connect_tokio_with_basic_auth(
                    &mut stream,
                    "api.openai.com",
                    443,
                    username,
                    password,
                )
                .await
                .map_err(|error| format!("GPT-Live proxy CONNECT failed: {error}"))?;
            } else {
                http_connect_tokio(&mut stream, "api.openai.com", 443)
                    .await
                    .map_err(|error| format!("GPT-Live proxy CONNECT failed: {error}"))?;
            }
            tokio_tungstenite::client_async_tls_with_config(request, stream, Some(config), None)
                .await
                .map_err(|error| format!("GPT-Live sideband connection failed: {error}"))
        } else {
            tokio_tungstenite::connect_async_with_config(request, Some(config), false)
                .await
                .map_err(|error| format!("GPT-Live sideband connection failed: {error}"))
        }
    };
    let (mut socket, _) = tokio::time::timeout(NETWORK_WAIT, connect)
        .await
        .map_err(|_| "GPT-Live sideband connection timed out".to_string())??;
    println!("GPT Live Beta probe: sideband connected; waiting for verified session activity…");

    let mut observed = Vec::new();
    let mut session_started = false;
    let mut session_activity_verified = false;
    let mut marker = TranscriptMarkerGate::new(LIVE_PROBE_MARKER)?;
    let startup = tokio::time::timeout(NETWORK_WAIT, async {
        loop {
            if session_activity_verified && *audio_verified.borrow() {
                return Ok(());
            }
            let message = tokio::select! {
                changed = audio_verified.changed(), if session_activity_verified => {
                    changed.map_err(|_| "GPT-Live audio proof ended during startup".to_string())?;
                    continue;
                }
                message = socket.next() => message,
            };
            let Some(message) = message else {
                return Err("GPT-Live sideband ended during startup".into());
            };
            match message.map_err(|error| format!("GPT-Live sideband read failed: {error}"))? {
                Message::Text(payload) => match parse_inbound_event(payload.as_ref()) {
                    Some(GptLiveInboundEvent::SessionStarted { .. }) => {
                        session_started = true;
                        session_activity_verified = true;
                        println!("GPT Live Beta probe: session.started received.");
                    }
                    Some(GptLiveInboundEvent::Error { message, .. }) => return Err(message),
                    Some(GptLiveInboundEvent::Ignored { event_type })
                    | Some(GptLiveInboundEvent::Unknown { event_type }) => {
                        record_event_type(&mut observed, &event_type)
                    }
                    Some(GptLiveInboundEvent::Audio { .. }) => {
                        record_event_type(&mut observed, "output_audio.delta")
                    }
                    Some(GptLiveInboundEvent::TranscriptDelta { role, text }) => {
                        if role == GptLiveRole::Assistant
                            && !session_activity_verified
                            && marker.observe(&text)
                        {
                            session_activity_verified = true;
                            println!(
                                "GPT Live Beta probe: expected assistant transcript received."
                            );
                        }
                        record_event_type(&mut observed, "transcript.added")
                    }
                    Some(GptLiveInboundEvent::TranscriptDone { role, text }) => {
                        if role == GptLiveRole::Assistant
                            && !session_activity_verified
                            && marker.observe(&text)
                        {
                            session_activity_verified = true;
                            println!(
                                "GPT Live Beta probe: expected assistant transcript received."
                            );
                        }
                        record_event_type(&mut observed, "turn.done")
                    }
                    Some(GptLiveInboundEvent::Delegation { .. }) => {
                        record_event_type(&mut observed, "delegation.created")
                    }
                    None => record_event_type(&mut observed, "unparseable-text"),
                },
                Message::Close(_) => return Err("GPT-Live sideband closed during startup".into()),
                Message::Ping(payload) => socket
                    .send(Message::Pong(payload))
                    .await
                    .map_err(|error| format!("GPT-Live sideband pong failed: {error}"))?,
                Message::Binary(_) | Message::Pong(_) | Message::Frame(_) => {}
            }
        }
    })
    .await;
    let result = match startup {
        Ok(result) => result,
        Err(_) if session_activity_verified => {
            let startup_evidence = if session_started {
                "session.started"
            } else {
                "the expected assistant transcript"
            };
            Err(format!(
                "GPT-Live reported {startup_evidence}, but audible model speech was not verified"
            ))
        }
        Err(_) if observed.is_empty() => {
            Err("GPT-Live sideband startup timed out without receiving any event".into())
        }
        Err(_) => Err(format!(
            "GPT-Live sideband startup timed out after event types: {}",
            observed.join(", ")
        )),
    };
    let _ = socket.close(None).await;
    result
}

fn record_event_type(observed: &mut Vec<String>, event_type: &str) {
    if observed.len() >= 16
        || event_type.is_empty()
        || event_type.len() > 80
        || !event_type
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return;
    }
    if !observed.iter().any(|value| value == event_type) {
        observed.push(event_type.into());
    }
}

fn now_ms() -> Result<u64, String> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "system clock is before the Unix epoch".to_string())?
        .as_millis();
    u64::try_from(millis).map_err(|_| "system clock is out of range".into())
}
