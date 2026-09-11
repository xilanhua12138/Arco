use std::env;
use std::os::unix::fs::PermissionsExt;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use arco_core::agent::AgentRunner;
use arco_core::gpt_live::{
    GptLiveAuth, GptLiveInboundEvent, GptLiveSession, RequestIds, UreqGptLiveCallTransport,
    create_call_with_transport, parse_inbound_event, sideband_auth_headers,
};
use arco_core::gpt_live_oauth::{
    FileGptLiveCredentialStorage, GptLiveCredentialStatus, GptLiveCredentialStorage,
    GptLiveCredentials, OPENAI_OAUTH_CALLBACK_HOST, TokenResult, UreqOAuthTokenTransport,
    create_default_authorization_flow, exchange_token_with_transport, extract_auth_identity,
    load_credentials_from, parse_callback_url, refresh_token_with_transport, save_credentials_to,
};
use arco_gpt_live::meeting_audio::{MeetingAudioBridge, MeteredSource, send_microphone};
use arco_gpt_live::{
    GptLiveMeetingContext, GptLiveRuntimeCommand, GptLiveSessionOptions, GptLiveWebRtcPeer,
    RecorderPcmFramer, RemotePlaybackPrebuffer, build_sideband_request,
    callback_url_from_http_request, parse_runtime_command, resolve_sideband_proxy,
};
use async_http_proxy::{http_connect_tokio, http_connect_tokio_with_basic_auth};
use futures_util::{SinkExt, StreamExt};
use rodio::{DeviceSinkBuilder, Player, buffer::SamplesBuffer, nz};
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::protocol::{Message, WebSocketConfig};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

const NETWORK_WAIT: Duration = Duration::from_secs(20);
const CALLBACK_WAIT: Duration = Duration::from_secs(180);
const SESSION_INSTRUCTIONS: &str = "You are Arco's live meeting voice assistant. Do not speak when the session starts. You are a participant in a multi-person hybrid meeting. Listen to both remote and in-room speakers. Stay silent unless the current human utterance directly addresses you as Arco, Hey Arco, or 阿可. An ordinary question or acknowledgement between humans does not invite you to speak. After responding yield the floor. Never speak acknowledgements to background conversation. Answer in the language used by the speaker and be concise enough to use during a live meeting. For every question that depends on the meeting transcript, what the participants discussed, decisions, action items, or the meeting's current progress, create a client delegation and wait for its supplied context before answering. Never guess meeting facts from general knowledge. You may answer general knowledge and casual conversation directly.";

type SidebandSocket = WebSocketStream<MaybeTlsStream<TcpStream>>;

enum StartupDecision {
    Ready,
    Stop,
}

fn main() {
    if matches!(env::args().nth(1).as_deref(), Some("session" | "login"))
        && let Err(error) = arco_core::network_environment::inherit_login_shell()
    {
        emit_event("error", Some(&error));
        std::process::exit(1);
    }
    run_async();
}

fn run_async() {
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .expect("GPT Live runtime");
    let result = runtime.block_on(run());
    // Tokio stdin uses a blocking read that cannot be cancelled by SIGTERM.
    // All session resources and the microphone route have already been dropped;
    // don't keep the worker alive waiting for another line on its input pipe.
    runtime.shutdown_timeout(Duration::from_millis(250));
    if let Err(error) = result {
        emit_event("error", Some(&error));
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let arguments = env::args().skip(1).collect::<Vec<_>>();
    match parse_runtime_command(&arguments)? {
        GptLiveRuntimeCommand::Session(options) => run_session(options).await,
        GptLiveRuntimeCommand::MicrophoneBridge(options) => run_microphone_bridge(options).await,
        GptLiveRuntimeCommand::MeetingAudioStatus => {
            println!(
                "{}",
                json!({"ready": arco_gpt_live::meeting_route::available()})
            );
            Ok(())
        }
        GptLiveRuntimeCommand::RecoverMeetingAudio => arco_gpt_live::meeting_route::recover_stale(),
        GptLiveRuntimeCommand::AuthStatus => show_auth_status(),
        GptLiveRuntimeCommand::Login => run_login().await,
        GptLiveRuntimeCommand::Logout => logout(),
    }
}

async fn run_session(options: GptLiveSessionOptions) -> Result<(), String> {
    ensure_executable(&options)?;

    emit_event("connecting", None);
    let meeting_bridge = MeetingAudioBridge::open(options.mode != "system")?;
    let storage = FileGptLiveCredentialStorage;
    let credentials = load_credentials_from(&storage)?
        .ok_or_else(|| "Sign in to ChatGPT for Arco GPT Live Beta, then retry.".to_string())?;
    let credentials = refresh_if_needed(credentials)?;
    save_credentials_to(&storage, &credentials)?;

    let auth = GptLiveAuth::oauth(credentials.access_token(), credentials.account_id())?;
    let request_ids = RequestIds::new();
    let session = GptLiveSession::new(SESSION_INSTRUCTIONS, None, vec![])?;
    let meeting_context =
        GptLiveMeetingContext::new(options.transcript.clone(), &options.provider)?;
    let peer = Arc::new(GptLiveWebRtcPeer::new().await?);

    let startup: Result<(SidebandSocket, Child), String> = async {
        let offer = peer.create_offer(Duration::from_secs(5)).await?;
        let call = create_call_with_transport(
            &UreqGptLiveCallTransport::default(),
            &auth,
            &request_ids,
            &offer,
            &session,
        )?;
        peer.apply_answer(&call.answer_sdp).await?;
        let socket = connect_sideband(&call.sideband_url, &auth, &request_ids).await?;
        peer.wait_connected(NETWORK_WAIT).await?;
        let recorder = start_recorder(&options)?;
        Ok((socket, recorder))
    }
    .await;

    let (socket, recorder) = match startup {
        Ok(value) => value,
        Err(error) => {
            let _ = peer.close().await;
            return Err(error);
        }
    };

    let output_meter = Arc::new(AtomicU32::new(0));
    let input_meter = Arc::new(AtomicU32::new(0));
    let thinking = Arc::new(AtomicBool::new(false));
    let permission = Arc::new(arco_gpt_live::voice_permission::VoicePermission::default());
    let (audio_ready_tx, audio_ready_rx) = oneshot::channel();
    let mut sender = tokio::spawn(pump_recorder_audio(
        Arc::clone(&peer),
        recorder,
        audio_ready_tx,
        Arc::clone(&input_meter),
    ));
    let mut receiver = tokio::spawn(play_remote_audio(
        Arc::clone(&peer),
        meeting_bridge.assistant.clone(),
        Arc::clone(&output_meter),
        Arc::clone(&permission),
    ));
    let delegation_cancelled = Arc::new(AtomicBool::new(false));
    let mut sideband = tokio::spawn(monitor_sideband(
        socket,
        meeting_context,
        Arc::clone(&delegation_cancelled),
        Arc::clone(&thinking),
        permission,
    ));
    let mut stop = Box::pin(wait_for_stop());

    let startup_result: Result<StartupDecision, String> = tokio::select! {
        ready = audio_ready_rx => ready
            .map(|_| StartupDecision::Ready)
            .map_err(|_| "GPT-Live recorder ended before audio became ready".to_string()),
        result = &mut sender => flatten_task("recorder audio", result).map(|_| StartupDecision::Stop),
        result = &mut receiver => flatten_task("remote audio", result).map(|_| StartupDecision::Stop),
        result = &mut sideband => flatten_task("sideband", result).map(|_| StartupDecision::Stop),
        _ = &mut stop => Ok(StartupDecision::Stop),
    };

    let telemetry = tokio::spawn(publish_voice_activity(
        input_meter,
        output_meter,
        thinking,
        meeting_bridge.assistant.is_some(),
    ));
    let result = match startup_result {
        Ok(StartupDecision::Ready) => {
            emit_event("connected", None);
            tokio::select! {
                result = &mut sender => flatten_task("recorder audio", result),
                result = &mut receiver => flatten_task("remote audio", result),
                result = &mut sideband => flatten_task("sideband", result),
                _ = &mut stop => Ok(()),
            }
        }
        Ok(StartupDecision::Stop) => Ok(()),
        Err(error) => Err(error),
    };

    telemetry.abort();
    emit_event("disconnecting", None);
    delegation_cancelled.store(true, Ordering::Release);
    sender.abort();
    receiver.abort();
    sideband.abort();
    let close = peer.close().await;
    result?;
    close
}

fn show_auth_status() -> Result<(), String> {
    let now = now_ms()?;
    let status = load_credentials_from(&FileGptLiveCredentialStorage)?
        .map(|credentials| credentials.status(now))
        .unwrap_or(GptLiveCredentialStatus {
            configured: false,
            valid: false,
            account_id: None,
            expires_at_ms: None,
            email: None,
            plan_type: None,
        });
    println!(
        "{}",
        serde_json::to_string(&status)
            .map_err(|_| "could not encode GPT Live sign-in status".to_string())?
    );
    Ok(())
}

async fn run_login() -> Result<(), String> {
    let flow = create_default_authorization_flow()?;
    let listener = TcpListener::bind((OPENAI_OAUTH_CALLBACK_HOST, 1455))
        .await
        .map_err(|error| format!("could not open the OAuth callback listener: {error}"))?;
    let status = Command::new("/usr/bin/open")
        .arg(&flow.authorization_url)
        .status()
        .await
        .map_err(|error| format!("could not open the ChatGPT sign-in page: {error}"))?;
    if !status.success() {
        return Err("macOS could not open the ChatGPT sign-in page".into());
    }

    let code = wait_for_oauth_code(listener, &flow.state).await?;
    let credentials = credentials_from_login_result(exchange_token_with_transport(
        &UreqOAuthTokenTransport::default(),
        &code,
        &flow.verifier,
        &flow.redirect_uri,
        now_ms()?,
    ))?;
    save_credentials_to(&FileGptLiveCredentialStorage, &credentials)?;
    show_auth_status()
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
    .map_err(|_| "ChatGPT sign-in timed out".to_string())?
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
    parse_callback_url(&callback_url_from_http_request(&request)?, expected_state)
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

fn logout() -> Result<(), String> {
    FileGptLiveCredentialStorage.delete()?;
    show_auth_status()
}

fn ensure_executable(options: &GptLiveSessionOptions) -> Result<(), String> {
    let metadata = std::fs::metadata(&options.recorder).map_err(|error| {
        format!(
            "GPT-Live recorder is unavailable at {}: {error}",
            options.recorder.display()
        )
    })?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(format!(
            "GPT-Live recorder is not executable: {}",
            options.recorder.display()
        ));
    }
    let transcript = std::fs::metadata(&options.transcript).map_err(|error| {
        format!(
            "GPT-Live meeting transcript is unavailable at {}: {error}",
            options.transcript.display()
        )
    })?;
    if !transcript.is_file() {
        return Err(format!(
            "GPT-Live meeting transcript is not a file: {}",
            options.transcript.display()
        ));
    }
    Ok(())
}

fn start_recorder(options: &GptLiveSessionOptions) -> Result<Child, String> {
    let mut command = Command::new(&options.recorder);
    if options.mode != "system" {
        command.env(
            "ARCO_MIC_DEVICE_ID",
            arco_gpt_live::meeting_route::physical_microphone_uid()?,
        );
    }
    command
        .arg(&options.mode)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env("ARCO_PARENT_PID", std::process::id().to_string())
        .env("ARCO_EXCLUDE_PARENT_AUDIO", "1")
        .kill_on_drop(true);
    command.spawn().map_err(|error| {
        format!(
            "GPT-Live could not start the Arco recorder at {}: {error}",
            options.recorder.display()
        )
    })
}

async fn pump_recorder_audio(
    peer: Arc<GptLiveWebRtcPeer>,
    mut recorder: Child,
    ready: oneshot::Sender<()>,
    input_meter: Arc<AtomicU32>,
) -> Result<(), String> {
    let mut output = recorder
        .stdout
        .take()
        .ok_or_else(|| "GPT-Live recorder did not expose its PCM stream".to_string())?;
    let mut framer = RecorderPcmFramer::new();
    let mut buffer = [0_u8; 6_400];
    let mut ready = Some(ready);
    loop {
        let read = output
            .read(&mut buffer)
            .await
            .map_err(|error| format!("GPT-Live could not read recorder audio: {error}"))?;
        if read == 0 {
            framer.finish()?;
            let status = recorder
                .wait()
                .await
                .map_err(|error| format!("GPT-Live could not inspect the recorder: {error}"))?;
            return Err(format!("GPT-Live recorder exited unexpectedly ({status})"));
        }
        for frame in framer.push(&buffer[..read])? {
            let sum = frame
                .iter()
                .map(|value| (f32::from(*value) / 32768.0).powi(2))
                .sum::<f32>();
            let level = (sum / frame.len().max(1) as f32).sqrt();
            input_meter.fetch_max(level.to_bits(), Ordering::Relaxed);
            peer.send_20ms_recorder_stereo(&frame).await?;
            if let Some(ready) = ready.take() {
                let _ = ready.send(());
            }
        }
    }
}

async fn play_remote_audio(
    peer: Arc<GptLiveWebRtcPeer>,
    meeting_assistant: Option<Arc<Player>>,
    meter: Arc<AtomicU32>,
    permission: Arc<arco_gpt_live::voice_permission::VoicePermission>,
) -> Result<(), String> {
    let mut output = DeviceSinkBuilder::open_default_sink()
        .map_err(|error| format!("GPT-Live could not open the default speaker: {error}"))?;
    output.log_on_drop(false);
    let player = Player::connect_new(output.mixer());
    let mut prebuffer = RemotePlaybackPrebuffer::gpt_live();
    let mut buffering = true;
    loop {
        let mut pcm = peer
            .receive_decoded_stereo(Duration::from_secs(31 * 60))
            .await?;
        if !permission.allowed() {
            player.clear();
            if let Some(sink) = &meeting_assistant {
                sink.clear();
            }
            prebuffer.reset();
            buffering = true;
            continue;
        }
        if !buffering && player.empty() {
            prebuffer.reset();
            buffering = true;
        }
        if buffering {
            let Some(buffered) = prebuffer.push(&pcm) else {
                continue;
            };
            pcm = buffered;
            buffering = false;
        }
        let samples = pcm
            .into_iter()
            .map(|sample| f32::from(sample) / 32_768.0)
            .collect::<Vec<_>>();
        if player.len() > 100
            || meeting_assistant
                .as_ref()
                .is_some_and(|sink| sink.len() > 100)
        {
            return Err("Arco audio playback fell behind; re-invite Arco to reconnect.".into());
        }
        if let Some(sink) = &meeting_assistant {
            sink.append(SamplesBuffer::new(nz!(2), nz!(48_000), samples.clone()));
            sink.play();
        }
        player.append(MeteredSource::new(
            SamplesBuffer::new(nz!(2), nz!(48_000), samples),
            Arc::clone(&meter),
        ));
        // clear() also pauses Rodio. Resume after an addressed turn opens the gate.
        player.play();
    }
}

async fn wait_for_stop() {
    let mut line = String::new();
    let mut input = BufReader::new(tokio::io::stdin());
    let _ = input.read_line(&mut line).await;
}

async fn connect_sideband(
    sideband_url: &str,
    auth: &GptLiveAuth,
    request_ids: &RequestIds,
) -> Result<SidebandSocket, String> {
    let request = build_sideband_request(sideband_url, &sideband_auth_headers(auth, request_ids)?)?;
    let mut config = WebSocketConfig::default();
    config.max_message_size = Some(16 * 1024 * 1024);
    config.max_frame_size = Some(16 * 1024 * 1024);
    let connect = async {
        if let Some(proxy) = resolve_sideband_proxy(sideband_url)? {
            let mut stream = TcpStream::connect((proxy.host(), proxy.port()))
                .await
                .map_err(|error| format!("GPT-Live could not connect to the proxy: {error}"))?;
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
                .map(|value| value.0)
                .map_err(|error| format!("GPT-Live sideband connection failed: {error}"))
        } else {
            tokio_tungstenite::connect_async_with_config(request, Some(config), false)
                .await
                .map(|value| value.0)
                .map_err(|error| format!("GPT-Live sideband connection failed: {error}"))
        }
    };
    tokio::time::timeout(NETWORK_WAIT, connect)
        .await
        .map_err(|_| "GPT-Live sideband connection timed out".to_string())?
}

async fn monitor_sideband(
    mut socket: SidebandSocket,
    meeting_context: GptLiveMeetingContext,
    cancellation: Arc<AtomicBool>,
    thinking: Arc<AtomicBool>,
    permission: Arc<arco_gpt_live::voice_permission::VoicePermission>,
) -> Result<(), String> {
    let (delegation_tx, mut delegation_rx) = mpsc::channel::<(String, String)>(8);
    let (answer_tx, mut answer_rx) = mpsc::channel::<Vec<serde_json::Value>>(8);
    let worker_cancellation = Arc::clone(&cancellation);
    tokio::spawn(async move {
        while let Some((id, prompt)) = delegation_rx.recv().await {
            if worker_cancellation.load(Ordering::Acquire) {
                break;
            }
            let context = meeting_context.clone();
            let cancellation = Arc::clone(&worker_cancellation);
            let answer = tokio::task::spawn_blocking(move || {
                context.answer_with(&id, &prompt, |provider, question, meeting| {
                    AgentRunner::default()
                        .run_cancellable(
                            provider,
                            question,
                            meeting,
                            "transcript",
                            None,
                            cancellation.as_ref(),
                        )
                        .map(|reply| reply.answer)
                })
            })
            .await;
            if worker_cancellation.load(Ordering::Acquire) {
                break;
            }
            let Ok(Ok(events)) = answer else { continue };
            if answer_tx.send(events).await.is_err() {
                break;
            }
        }
    });

    loop {
        tokio::select! {
            message = socket.next() => {
                let Some(message) = message else {
                    return Err("GPT-Live sideband ended unexpectedly".into());
                };
                match message.map_err(|error| format!("GPT-Live sideband read failed: {error}"))? {
            Message::Text(payload) => {
                        match parse_inbound_event(payload.as_ref()) {
                            Some(GptLiveInboundEvent::TranscriptDelta { role: arco_core::gpt_live::GptLiveRole::User, text }) => permission.input(&text, false),
                            Some(GptLiveInboundEvent::TranscriptDone { role: arco_core::gpt_live::GptLiveRole::User, text }) => permission.input(&text, true),
                            Some(GptLiveInboundEvent::Error { message, .. }) => return Err(message),
                            Some(GptLiveInboundEvent::Delegation { id, prompt })
                                if !prompt.trim().is_empty() =>
                            {
                                thinking.store(true, Ordering::Relaxed);
                                delegation_tx
                                    .send((id, prompt))
                                    .await
                                    .map_err(|_| "GPT-Live meeting agent stopped unexpectedly".to_string())?;
                            }
                            _ => {}
                        }
                    }
                    Message::Ping(payload) => socket
                        .send(Message::Pong(payload))
                        .await
                        .map_err(|error| format!("GPT-Live sideband pong failed: {error}"))?,
                    Message::Close(_) => {
                        return Err("GPT-Live sideband closed unexpectedly".into());
                    }
                    Message::Binary(_) | Message::Pong(_) | Message::Frame(_) => {}
                }
            }
            answer = answer_rx.recv() => {
                let Some(events) = answer else {
                    return Err("GPT-Live meeting agent stopped unexpectedly".into());
                };
                thinking.store(false, Ordering::Relaxed);
                for event in events {
                    socket
                        .send(Message::Text(event.to_string().into()))
                        .await
                        .map_err(|error| format!("GPT-Live delegation response failed: {error}"))?;
                }
            }
        }
    }
}

fn flatten_task(
    label: &str,
    result: Result<Result<(), String>, tokio::task::JoinError>,
) -> Result<(), String> {
    match result {
        Ok(Ok(())) => Err(format!("GPT-Live {label} ended unexpectedly")),
        Ok(Err(error)) => Err(error),
        Err(error) => Err(format!("GPT-Live {label} task failed: {error}")),
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

fn now_ms() -> Result<u64, String> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "system clock is before the Unix epoch".to_string())?
        .as_millis();
    u64::try_from(millis).map_err(|_| "system clock is out of range".into())
}

fn emit_event(state: &str, message: Option<&str>) {
    let payload = match message {
        Some(message) => json!({ "type": "status", "state": state, "message": message }),
        None => json!({ "type": "status", "state": state }),
    };
    eprintln!("{payload}");
}

async fn publish_voice_activity(
    input: Arc<AtomicU32>,
    output: Arc<AtomicU32>,
    thinking: Arc<AtomicBool>,
    meeting_output: bool,
) {
    let mut interval = tokio::time::interval(Duration::from_millis(100));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut last_voice = std::time::Instant::now() - Duration::from_secs(1);
    loop {
        interval.tick().await;
        let input_level = f32::from_bits(input.swap(0, Ordering::Relaxed));
        let output_level = f32::from_bits(output.swap(0, Ordering::Relaxed));
        if output_level > 0.002 {
            last_voice = std::time::Instant::now();
        }
        let speaking = last_voice.elapsed() < Duration::from_millis(250);
        let state = if speaking {
            "speaking"
        } else if thinking.load(Ordering::Relaxed) {
            "thinking"
        } else {
            "listening"
        };
        let level = if speaking { output_level } else { input_level };
        eprintln!(
            "{}",
            json!({
                "type": "status", "state": state,
                "audioLevel": (level * 5.0).clamp(0.0, 1.0), "meetingOutput": meeting_output,
            })
        );
    }
}

// The desktop owns this send bus for one invitation. Stopping or losing the
// invitation restores the physical default input before the bridge exits.
async fn run_microphone_bridge(options: GptLiveSessionOptions) -> Result<(), String> {
    ensure_executable(&options)?;
    let bridge = MeetingAudioBridge::open(options.mode != "system")?;
    let Some(player) = bridge.microphone.as_ref() else {
        emit_event("connected", None);
        wait_for_stop().await;
        return Ok(());
    };
    let mut recorder = start_recorder(&options)?;
    let mut output = recorder
        .stdout
        .take()
        .ok_or("Meeting microphone PCM is unavailable")?;
    let mut framer = RecorderPcmFramer::new();
    let mut buffer = [0_u8; 6400];
    let mut ready = false;
    let mut route = None;
    let mut health = tokio::time::interval(Duration::from_millis(250));
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .map_err(|e| e.to_string())?;
    let mut stop = Box::pin(wait_for_stop());
    loop {
        tokio::select! {
            _ = &mut stop => break,
            _ = terminate.recv() => break,
            _ = health.tick() => {
                if route.as_ref().is_some_and(|r: &arco_gpt_live::meeting_route::MeetingRoute| !r.connected()) {
                    return Err("Meeting audio device changed. Invite Arco again to reconnect.".into());
                }
            }
            read = output.read(&mut buffer) => {
                let read = read.map_err(|error| format!("Meeting microphone capture failed: {error}"))?;
                if read == 0 { return Err("Meeting microphone capture ended unexpectedly".into()); }
                for frame in framer.push(&buffer[..read])? {
                    send_microphone(player, &frame)?;
                    if !ready {
                        route = Some(arco_gpt_live::meeting_route::MeetingRoute::connect()?);
                        eprintln!("{}", json!({"type": "status", "state": "connected", "meetingOutput": true}));
                        ready = true;
                    }
                }
            }
        }
    }
    recorder.kill().await.ok();
    recorder.wait().await.ok();
    Ok(())
}
