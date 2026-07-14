use crate::agent::is_executable;
use crate::meetings::meeting_id;
use crate::models::{CaptureState, TranscriptionConfig};
use crate::paths::AppPaths;
use crate::process::{configure_process_group, terminate_process_tree};
use crate::storage::MeetingRoot;
use chrono::Local;
use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

const MAX_RECORDER_READY_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct CommandSpec {
    pub program: PathBuf,
    pub args: Vec<OsString>,
}

impl CommandSpec {
    pub fn new(program: PathBuf, args: Vec<OsString>) -> Self {
        Self { program, args }
    }
}

#[derive(Clone, Debug)]
pub enum RecorderSpec {
    Executable(PathBuf),
    SwiftSource { source: PathBuf, output: PathBuf },
}

#[derive(Clone, Debug)]
pub struct CaptureConfig {
    pub transcript_dir: PathBuf,
    pub log_dir: PathBuf,
    pub recorder: RecorderSpec,
    pub transcribers: TranscriberCatalog,
    pub environment: HashMap<String, String>,
    pub requires_ready_signal: bool,
}

#[derive(Clone, Debug)]
pub struct TranscriberDefinition {
    pub command: CommandSpec,
    pub requires_deepgram_key: bool,
    pub requires_elevenlabs_key: bool,
    pub ready_timeout: Duration,
}

#[derive(Clone, Debug)]
pub struct TranscriberCatalog {
    pub deepgram: TranscriberDefinition,
    pub elevenlabs: TranscriberDefinition,
    pub local: Option<TranscriberDefinition>,
}

impl CaptureConfig {
    pub fn discover(paths: &AppPaths) -> Self {
        let log_dir = paths.app_data.join("logs");
        if let Err(error) = cleanup_stale_ready_signals(&log_dir) {
            log::warn!(
                "Arco could not clear stale audio readiness signals in {}: {error}",
                log_dir.display()
            );
        }
        let recorder = std::env::var_os("ARCO_RECORDER_BIN")
            .map(PathBuf::from)
            .map(RecorderSpec::Executable)
            .unwrap_or_else(|| {
                let bundled_binary = paths.native_dir.join("recorder");
                if is_executable(&bundled_binary) {
                    RecorderSpec::Executable(bundled_binary)
                } else {
                    RecorderSpec::SwiftSource {
                        source: paths.native_dir.join("recorder.swift"),
                        output: paths.app_data.join("bin").join("arco-recorder"),
                    }
                }
            });

        let (deepgram_command, requires_deepgram_key) =
            if let Some(binary) = std::env::var_os("ARCO_TRANSCRIBER_BIN") {
                (CommandSpec::new(PathBuf::from(binary), Vec::new()), false)
            } else {
                (
                    CommandSpec::new(discover_deepgram_transcriber(paths), Vec::new()),
                    true,
                )
            };

        let local_binary = discover_local_transcriber(paths);
        let elevenlabs_command = std::env::var_os("ARCO_ELEVENLABS_TRANSCRIBER_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|| discover_elevenlabs_transcriber(paths));
        let environment = load_capture_environment(paths);
        Self {
            transcript_dir: paths.transcripts.clone(),
            log_dir,
            recorder,
            transcribers: TranscriberCatalog {
                deepgram: TranscriberDefinition {
                    command: deepgram_command,
                    requires_deepgram_key,
                    requires_elevenlabs_key: false,
                    ready_timeout: Duration::from_secs(20),
                },
                elevenlabs: TranscriberDefinition {
                    command: CommandSpec::new(elevenlabs_command, Vec::new()),
                    requires_deepgram_key: false,
                    requires_elevenlabs_key: true,
                    ready_timeout: Duration::from_secs(20),
                },
                local: local_binary.map(|program| TranscriberDefinition {
                    command: CommandSpec::new(program, vec![OsString::from("stream")]),
                    requires_deepgram_key: false,
                    requires_elevenlabs_key: false,
                    // The ASR model is fast once loaded, but a first Core ML
                    // compilation for Streaming Sortformer can take minutes.
                    ready_timeout: Duration::from_secs(300),
                }),
            },
            environment,
            requires_ready_signal: true,
        }
    }
}

fn cleanup_stale_ready_signals(log_dir: &Path) -> std::io::Result<()> {
    if !log_dir.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(log_dir)? {
        let entry = entry?;
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let is_pipeline_signal = name.ends_with(".signal")
            && (name.starts_with("recorder-ready-") || name.starts_with("transcriber-ready-"));
        if is_pipeline_signal {
            fs::remove_file(entry.path())?;
        }
    }
    Ok(())
}

pub fn discover_deepgram_transcriber(paths: &AppPaths) -> PathBuf {
    [
        paths.native_dir.join("arco-deepgram-transcriber"),
        paths
            .native_dir
            .join("runtime")
            .join("arco-deepgram-transcriber"),
    ]
    .into_iter()
    .find(|path| is_executable(path))
    .unwrap_or_else(|| paths.native_dir.join("arco-deepgram-transcriber"))
}

pub fn discover_elevenlabs_transcriber(paths: &AppPaths) -> PathBuf {
    [
        paths.native_dir.join("arco-elevenlabs-transcriber"),
        paths
            .native_dir
            .join("runtime")
            .join("arco-elevenlabs-transcriber"),
    ]
    .into_iter()
    .find(|path| is_executable(path))
    .unwrap_or_else(|| paths.native_dir.join("arco-elevenlabs-transcriber"))
}

pub fn discover_local_transcriber(paths: &AppPaths) -> Option<PathBuf> {
    std::env::var_os("ARCO_LOCAL_TRANSCRIBER_BIN")
        .map(PathBuf::from)
        .filter(|path| is_executable(path))
        .or_else(|| {
            [
                paths.native_dir.join("arco-local-transcriber"),
                paths
                    .native_dir
                    .join("runtime")
                    .join("arco-local-transcriber"),
                paths
                    .native_dir
                    .join("local-transcriber")
                    .join(".build")
                    .join("release")
                    .join("arco-local-transcriber"),
            ]
            .into_iter()
            .find(|path| is_executable(path))
        })
}

struct CaptureChildren {
    recorder: Child,
    transcriber: Child,
}

struct PipelineReadySignals {
    recorder: PathBuf,
    transcriber: PathBuf,
}

impl PipelineReadySignals {
    fn new(log_dir: &Path, suffix: &str) -> Self {
        let signals = Self {
            recorder: log_dir.join(format!("recorder-ready-{suffix}.signal")),
            transcriber: log_dir.join(format!("transcriber-ready-{suffix}.signal")),
        };
        signals.clear();
        signals
    }

    fn clear(&self) {
        let _ = fs::remove_file(&self.recorder);
        let _ = fs::remove_file(&self.transcriber);
    }
}

impl Drop for PipelineReadySignals {
    fn drop(&mut self) {
        self.clear();
    }
}

struct CaptureInner {
    state: CaptureState,
    children: Option<CaptureChildren>,
    transcript: Option<PathBuf>,
}

pub struct CaptureManager {
    config: CaptureConfig,
    destination: Mutex<MeetingRoot>,
    inner: Mutex<CaptureInner>,
}

impl CaptureManager {
    pub fn new(config: CaptureConfig) -> Self {
        let destination = MeetingRoot {
            source: "local".into(),
            path: config.transcript_dir.clone(),
        };
        Self {
            config,
            destination: Mutex::new(destination),
            inner: Mutex::new(CaptureInner {
                state: CaptureState::idle(None::<String>),
                children: None,
                transcript: None,
            }),
        }
    }

    pub fn set_transcript_root(&self, root: MeetingRoot) -> Result<(), String> {
        let inner = self.inner.lock().unwrap_or_else(|lock| lock.into_inner());
        if inner.children.is_some()
            || matches!(
                inner.state.phase.as_str(),
                "starting" | "recording" | "stopping"
            )
        {
            return Err("stop the current meeting before changing transcript storage".into());
        }
        let mut destination = self
            .destination
            .lock()
            .map_err(|_| "transcript storage destination is unavailable".to_string())?;
        *destination = root;
        Ok(())
    }

    pub fn status(&self) -> CaptureState {
        let mut inner = self.inner.lock().unwrap_or_else(|lock| lock.into_inner());
        refresh_children(&mut inner);
        inner.state.clone()
    }

    pub fn active_transcript_path(&self) -> Option<PathBuf> {
        let mut inner = self.inner.lock().unwrap_or_else(|lock| lock.into_inner());
        refresh_children(&mut inner);
        if matches!(inner.state.phase.as_str(), "starting" | "recording") {
            inner.transcript.clone()
        } else {
            None
        }
    }

    pub fn start(&self, mode: &str) -> Result<CaptureState, String> {
        self.start_with_transcription(mode, TranscriptionConfig::default())
    }

    pub fn start_with_transcription(
        &self,
        mode: &str,
        transcription: TranscriptionConfig,
    ) -> Result<CaptureState, String> {
        self.start_with_transcription_and_secret(mode, transcription, None)
    }

    pub fn start_with_transcription_and_secret(
        &self,
        mode: &str,
        transcription: TranscriptionConfig,
        provider_api_key: Option<String>,
    ) -> Result<CaptureState, String> {
        validate_mode(mode)?;
        transcription.validate()?;
        let mut inner = self.inner.lock().unwrap_or_else(|lock| lock.into_inner());
        refresh_children(&mut inner);
        if inner.children.is_some()
            || matches!(
                inner.state.phase.as_str(),
                "starting" | "recording" | "stopping"
            )
        {
            return Err("a capture session is already running".into());
        }

        inner.state = CaptureState {
            phase: "starting".into(),
            active_meeting_id: None,
            started_at: None,
            message: Some("Preparing native audio capture…".into()),
            mode: Some(mode.into()),
            transcript_path: None,
            error: None,
            transcription: Some(transcription.clone()),
        };

        match self.spawn_pipeline(mode, &transcription, provider_api_key.as_deref()) {
            Ok((children, transcript, started_at, source)) => {
                let id = meeting_id(&source, &transcript)?;
                inner.transcript = Some(transcript.clone());
                inner.children = Some(children);
                inner.state = CaptureState {
                    phase: "recording".into(),
                    active_meeting_id: Some(id),
                    started_at: Some(started_at),
                    message: Some("Listening to system audio and microphone".into()),
                    mode: Some(mode.into()),
                    transcript_path: Some(transcript.to_string_lossy().into_owned()),
                    error: None,
                    transcription: Some(transcription.clone()),
                };
                Ok(inner.state.clone())
            }
            Err(error) => {
                inner.children = None;
                inner.transcript = None;
                inner.state = CaptureState {
                    phase: "error".into(),
                    active_meeting_id: None,
                    started_at: None,
                    message: Some(error.clone()),
                    mode: Some(mode.into()),
                    transcript_path: None,
                    error: Some(error.clone()),
                    transcription: Some(transcription),
                };
                Err(error)
            }
        }
    }

    pub fn stop(&self) -> Result<CaptureState, String> {
        let mut inner = self.inner.lock().unwrap_or_else(|lock| lock.into_inner());
        refresh_children(&mut inner);
        let Some(mut children) = inner.children.take() else {
            inner.transcript = None;
            inner.state = CaptureState::idle(Some("No capture is running".into()));
            return Ok(inner.state.clone());
        };

        inner.state.phase = "stopping".into();
        inner.state.message = Some("Finalizing transcript…".into());

        // Only these two Child handles are touched. Arco never scans the global
        // process table and never sends signals to another recorder/listener.
        terminate_recorder_then_transcriber(&mut children);
        let transcript = inner.transcript.take();
        if let Some(path) = transcript.as_deref() {
            finalize_transcript(path, "stopped")?;
        }
        inner.state = CaptureState::idle(Some("Capture stopped and transcript saved".into()));
        Ok(inner.state.clone())
    }

    pub fn shutdown(&self) {
        let mut inner = self.inner.lock().unwrap_or_else(|lock| lock.into_inner());
        interrupt_active_capture(&mut inner);
    }

    fn spawn_pipeline(
        &self,
        mode: &str,
        transcription: &TranscriptionConfig,
        provider_api_key: Option<&str>,
    ) -> Result<(CaptureChildren, PathBuf, String, String), String> {
        let destination = self
            .destination
            .lock()
            .map_err(|_| "transcript storage destination is unavailable".to_string())?
            .clone();
        let transcript_dir = destination.path;
        let transcriber_definition = self.resolve_transcriber(transcription)?;
        if transcriber_definition.requires_deepgram_key
            && provider_api_key
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .is_none()
            && !self
                .config
                .environment
                .get("DEEPGRAM_API_KEY")
                .map(|value| !value.trim().is_empty())
                .unwrap_or(false)
            && std::env::var("DEEPGRAM_API_KEY")
                .map(|value| value.trim().is_empty())
                .unwrap_or(true)
        {
            return Err("Deepgram is not configured. Paste your API key in Arco Settings → Audio & speakers → Recognition.".into());
        }
        if transcriber_definition.requires_elevenlabs_key
            && provider_api_key
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .is_none()
            && !self
                .config
                .environment
                .get("ELEVENLABS_API_KEY")
                .map(|value| !value.trim().is_empty())
                .unwrap_or(false)
            && std::env::var("ELEVENLABS_API_KEY")
                .map(|value| value.trim().is_empty())
                .unwrap_or(true)
        {
            return Err("ElevenLabs is not configured. Paste your API key in Arco Settings → Audio & speakers → Recognition.".into());
        }

        fs::create_dir_all(&transcript_dir).map_err(|error| {
            format!(
                "could not create transcript directory {}: {error}",
                transcript_dir.display()
            )
        })?;
        fs::create_dir_all(&self.config.log_dir).map_err(|error| {
            format!(
                "could not create log directory {}: {error}",
                self.config.log_dir.display()
            )
        })?;
        let recorder_binary = ensure_recorder(&self.config.recorder)?;
        if !is_executable(&recorder_binary) {
            return Err(format!(
                "native recorder is not executable: {}",
                recorder_binary.display()
            ));
        }
        if !is_executable(&transcriber_definition.command.program) {
            return Err(format!(
                "transcriber runtime is not executable: {}",
                transcriber_definition.command.program.display()
            ));
        }

        let now = Local::now();
        let started_at = now.to_rfc3339();
        let session_started_at_unix = format!("{:.3}", now.timestamp_millis() as f64 / 1_000.0);
        let transcript = create_transcript(
            &transcript_dir,
            &now.format("%Y%m%d-%H%M%S").to_string(),
            &now.format("%Y-%m-%d %H:%M:%S").to_string(),
        )?;

        let recorder_log = open_log(&self.config.log_dir.join("recorder.log"))?;
        let transcriber_log = open_log(&self.config.log_dir.join("transcriber.log"))?;
        let ready_signals = PipelineReadySignals::new(
            &self.config.log_dir,
            &format!("{}-{}", std::process::id(), now.timestamp_micros()),
        );
        let mut recorder_command = Command::new(&recorder_binary);
        recorder_command
            .arg(mode)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(recorder_log.try_clone().map_err(|error| {
                format!("could not clone recorder log: {error}")
            })?))
            .envs(&self.config.environment)
            .env("ARCO_PARENT_PID", std::process::id().to_string())
            .env("ARCO_RECORDER_READY_FILE", &ready_signals.recorder);
        configure_process_group(&mut recorder_command)
            .map_err(|error| format!("could not isolate native recorder process: {error}"))?;
        let mut recorder = recorder_command
            .spawn()
            .map_err(|error| format!("could not start native recorder: {error}"))?;
        let recorder_stdout = match recorder.stdout.take() {
            Some(stdout) => stdout,
            None => {
                let _ = terminate_process_tree(&mut recorder, Duration::from_millis(250));
                return Err("native recorder did not expose its audio stream".into());
            }
        };

        let mut transcriber_command = Command::new(&transcriber_definition.command.program);
        transcriber_command
            .args(&transcriber_definition.command.args)
            .arg(&transcript)
            .stdin(Stdio::from(recorder_stdout))
            .stdout(Stdio::from(transcriber_log.try_clone().map_err(
                |error| format!("could not clone transcriber log: {error}"),
            )?))
            .stderr(Stdio::from(transcriber_log))
            .envs(&self.config.environment)
            .env("ARCO_READY_FILE", &ready_signals.transcriber)
            .env("ARCO_AUDIO_MODE", mode)
            .env("ARCO_SESSION_STARTED_AT_UNIX", &session_started_at_unix);
        if let Some(api_key) = provider_api_key
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            transcriber_command.env(
                if transcription.provider == "elevenlabs" {
                    "ELEVENLABS_API_KEY"
                } else {
                    "DEEPGRAM_API_KEY"
                },
                api_key,
            );
        }
        if let Err(error) = configure_process_group(&mut transcriber_command) {
            let _ = terminate_process_tree(&mut recorder, Duration::from_millis(250));
            let _ = finalize_transcript(&transcript, "error");
            return Err(format!(
                "could not isolate live transcriber process: {error}"
            ));
        }
        let transcriber = match transcriber_command.spawn() {
            Ok(child) => child,
            Err(error) => {
                let _ = terminate_process_tree(&mut recorder, Duration::from_millis(250));
                let _ = finalize_transcript(&transcript, "error");
                return Err(format!("could not start live transcriber: {error}"));
            }
        };

        let mut children = CaptureChildren {
            recorder,
            transcriber,
        };
        if self.config.requires_ready_signal {
            if let Err(error) = wait_for_pipeline_ready(
                &mut children,
                &ready_signals.recorder,
                &ready_signals.transcriber,
                transcriber_definition.ready_timeout,
            ) {
                terminate_recorder_then_transcriber(&mut children);
                let _ = finalize_transcript(&transcript, "error");
                return Err(error);
            }
        }

        Ok((children, transcript, started_at, destination.source))
    }

    fn resolve_transcriber(
        &self,
        transcription: &TranscriptionConfig,
    ) -> Result<TranscriberDefinition, String> {
        if transcription.provider == "deepgram" {
            return Ok(self.config.transcribers.deepgram.clone());
        }
        if transcription.provider == "elevenlabs" {
            return Ok(self.config.transcribers.elevenlabs.clone());
        }
        let mut local = self.config.transcribers.local.clone().ok_or_else(|| {
            "The on-device transcription runtime is not installed. Build or reinstall Arco to add local speech models."
                .to_string()
        })?;
        local.command.args.extend([
            OsString::from("--model"),
            OsString::from(&transcription.model),
            OsString::from("--language"),
            OsString::from(&transcription.language),
            OsString::from("--diarization"),
            OsString::from(&transcription.diarization),
        ]);
        Ok(local)
    }
}

impl Drop for CaptureManager {
    fn drop(&mut self) {
        let inner = self
            .inner
            .get_mut()
            .unwrap_or_else(|lock| lock.into_inner());
        interrupt_active_capture(inner);
    }
}

fn interrupt_active_capture(inner: &mut CaptureInner) {
    if let Some(mut children) = inner.children.take() {
        terminate_recorder_then_transcriber(&mut children);
        if let Some(path) = inner.transcript.take() {
            let _ = finalize_transcript(&path, "interrupted");
        }
    }
    inner.transcript = None;
    inner.state = CaptureState::idle(Some("Capture interrupted because Arco closed".into()));
}

fn wait_for_pipeline_ready(
    children: &mut CaptureChildren,
    recorder_ready_file: &Path,
    transcriber_ready_file: &Path,
    transcriber_timeout: Duration,
) -> Result<(), String> {
    let started = Instant::now();
    let recorder_timeout = transcriber_timeout.min(MAX_RECORDER_READY_TIMEOUT);
    loop {
        match children.recorder.try_wait() {
            Ok(Some(status)) => {
                return Err(format!(
                    "native recorder exited before transcription readiness ({status})"
                ))
            }
            Err(error) => {
                return Err(format!(
                    "could not inspect native recorder while starting: {error}"
                ))
            }
            Ok(None) => {}
        }
        match children.transcriber.try_wait() {
            Ok(Some(status)) => {
                return Err(format!(
                    "live transcriber exited before readiness ({status})"
                ))
            }
            Err(error) => {
                return Err(format!(
                    "could not inspect live transcriber while starting: {error}"
                ))
            }
            Ok(None) => {}
        }
        let recorder_ready = recorder_ready_file.is_file();
        let transcriber_ready = transcriber_ready_file.is_file();
        if recorder_ready && transcriber_ready {
            return Ok(());
        }
        if !recorder_ready && started.elapsed() >= recorder_timeout {
            return Err(format!(
                "native recorder did not become ready within {:.1} seconds",
                recorder_timeout.as_secs_f64()
            ));
        }
        if !transcriber_ready && started.elapsed() >= transcriber_timeout {
            return Err(format!(
                "live transcriber did not become ready within {:.1} seconds",
                transcriber_timeout.as_secs_f64()
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn validate_mode(mode: &str) -> Result<(), String> {
    match mode {
        "both" | "system" | "mic" => Ok(()),
        _ => Err(format!(
            "unsupported capture mode: {mode}; expected both, system, or mic"
        )),
    }
}

fn refresh_children(inner: &mut CaptureInner) {
    let Some(children) = inner.children.as_mut() else {
        return;
    };
    let recorder_status = children.recorder.try_wait();
    let transcriber_status = children.transcriber.try_wait();
    let failure = match (recorder_status, transcriber_status) {
        (_, Err(error)) => Some(format!("could not inspect live transcriber: {error}")),
        (Err(error), _) => Some(format!("could not inspect native recorder: {error}")),
        (Ok(recorder), Ok(transcriber)) => match (recorder, transcriber) {
            // A failed transcriber closes its stdin and can make the recorder
            // receive SIGPIPE. Preserve the causal transcriber exit in that race.
            (_, Some(status)) if !status.success() => {
                Some(format!("live transcriber exited unexpectedly ({status})"))
            }
            (Some(status), _) if !status.success() => {
                Some(format!("native recorder exited unexpectedly ({status})"))
            }
            (_, Some(status)) => Some(format!("live transcriber exited unexpectedly ({status})")),
            (Some(status), _) => Some(format!("native recorder exited unexpectedly ({status})")),
            (None, None) => None,
        },
    };
    let Some(error) = failure else {
        return;
    };

    if let Some(mut children) = inner.children.take() {
        terminate_recorder_then_transcriber(&mut children);
    }
    if let Some(path) = inner.transcript.as_deref() {
        let _ = finalize_transcript(path, "error");
    }
    inner.state.phase = "error".into();
    inner.state.active_meeting_id = None;
    inner.state.message = Some(error.clone());
    inner.state.error = Some(error);
}

fn terminate_recorder_then_transcriber(children: &mut CaptureChildren) {
    let _ = terminate_process_tree(&mut children.recorder, Duration::from_millis(500));

    match children
        .transcriber
        .wait_timeout(Duration::from_secs(2))
        .ok()
        .flatten()
    {
        Some(_) => {
            // A helper may exit before one of its descendants. Signal the
            // owned process group as a final sweep.
            let _ = terminate_process_tree(&mut children.transcriber, Duration::ZERO);
        }
        None => {
            let _ = terminate_process_tree(&mut children.transcriber, Duration::from_millis(500));
        }
    }
}

fn ensure_recorder(spec: &RecorderSpec) -> Result<PathBuf, String> {
    match spec {
        RecorderSpec::Executable(path) => Ok(path.clone()),
        RecorderSpec::SwiftSource { source, output } => {
            #[cfg(not(target_os = "macos"))]
            {
                let _ = (source, output);
                return Err("native meeting capture currently requires macOS".into());
            }
            #[cfg(target_os = "macos")]
            {
                if !source.is_file() {
                    return Err(format!(
                        "native recorder source is missing: {}",
                        source.display()
                    ));
                }
                let source_modified = fs::metadata(source)
                    .and_then(|metadata| metadata.modified())
                    .ok();
                let output_modified = fs::metadata(output)
                    .and_then(|metadata| metadata.modified())
                    .ok();
                let rebuild = !is_executable(output) || source_modified > output_modified;
                if !rebuild {
                    return Ok(output.clone());
                }
                let parent = output
                    .parent()
                    .ok_or_else(|| "invalid recorder output path".to_string())?;
                fs::create_dir_all(parent).map_err(|error| {
                    format!("could not create native binary directory: {error}")
                })?;
                let temporary = output.with_extension(format!("tmp-{}", std::process::id()));
                let swiftc = find_command("swiftc").ok_or_else(|| {
                    "swiftc was not found; install Xcode Command Line Tools".to_string()
                })?;
                let mut build_command = Command::new(swiftc);
                let swift_target = match std::env::consts::ARCH {
                    "aarch64" => "arm64-apple-macosx14.0",
                    "x86_64" => "x86_64-apple-macosx14.0",
                    architecture => {
                        return Err(format!(
                            "unsupported macOS architecture for recorder: {architecture}"
                        ))
                    }
                };
                build_command
                    .arg("-target")
                    .arg(swift_target)
                    .arg(source)
                    .arg("-o")
                    .arg(&temporary)
                    .args([
                        "-framework",
                        "ScreenCaptureKit",
                        "-framework",
                        "AVFoundation",
                        "-framework",
                        "CoreMedia",
                    ]);
                let helper_info_plist = source.with_file_name("recorder-Info.plist");
                if helper_info_plist.is_file() {
                    build_command.args([
                        OsString::from("-Xlinker"),
                        OsString::from("-sectcreate"),
                        OsString::from("-Xlinker"),
                        OsString::from("__TEXT"),
                        OsString::from("-Xlinker"),
                        OsString::from("__info_plist"),
                        OsString::from("-Xlinker"),
                        helper_info_plist.into_os_string(),
                    ]);
                }
                let build = build_command
                    .output()
                    .map_err(|error| format!("could not run swiftc: {error}"))?;
                if !build.status.success() {
                    let _ = fs::remove_file(&temporary);
                    return Err(format!(
                        "native recorder build failed: {}",
                        String::from_utf8_lossy(&build.stderr).trim()
                    ));
                }
                let codesign = find_command("codesign").ok_or_else(|| {
                    "codesign was not found; install Xcode Command Line Tools".to_string()
                })?;
                let signing = Command::new(codesign)
                    .args(["--force", "--sign", "-"])
                    .arg(&temporary)
                    .output()
                    .map_err(|error| format!("could not run codesign: {error}"))?;
                if !signing.status.success() {
                    let _ = fs::remove_file(&temporary);
                    return Err(format!(
                        "native recorder signing failed: {}",
                        String::from_utf8_lossy(&signing.stderr).trim()
                    ));
                }
                fs::rename(&temporary, output)
                    .map_err(|error| format!("could not install native recorder: {error}"))?;
                Ok(output.clone())
            }
        }
    }
}

fn create_transcript(
    directory: &Path,
    timestamp: &str,
    started_at: &str,
) -> Result<PathBuf, String> {
    for attempt in 0..1000 {
        let suffix = if attempt == 0 {
            String::new()
        } else {
            format!("-{attempt}")
        };
        let path = directory.join(format!("transcript-{timestamp}{suffix}.md"));
        let mut file = match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(format!(
                    "could not create transcript {}: {error}",
                    path.display()
                ))
            }
        };
        write!(
            file,
            "# Meeting Transcript\n\n> Started: {started_at} (live)\n\n"
        )
        .map_err(|error| format!("could not initialize transcript: {error}"))?;
        return Ok(path);
    }
    Err("could not allocate a unique transcript filename".into())
}

fn finalize_transcript(path: &Path, outcome: &str) -> Result<(), String> {
    let raw = fs::read_to_string(path)
        .map_err(|error| format!("could not read transcript while finalizing: {error}"))?;
    let raw = raw.replacen(" (live)", &format!(" ({outcome})"), 1);
    let mut file =
        File::create(path).map_err(|error| format!("could not finalize transcript: {error}"))?;
    file.write_all(raw.as_bytes())
        .and_then(|_| {
            writeln!(
                file,
                "\n> Ended: {} ({outcome})",
                Local::now().format("%Y-%m-%d %H:%M:%S")
            )
        })
        .map_err(|error| format!("could not finalize transcript: {error}"))
}

fn open_log(path: &Path) -> Result<File, String> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| format!("could not open {}: {error}", path.display()))
}

fn find_command(name: &str) -> Option<PathBuf> {
    if let Some(found) = std::env::var_os("PATH")
        .unwrap_or_default()
        .to_string_lossy()
        .split(':')
        .filter(|segment| !segment.is_empty())
        .map(Path::new)
        .map(|directory| directory.join(name))
        .find(|path| is_executable(path))
    {
        return Some(found);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from);
    command_candidates(home.as_deref(), name)
        .into_iter()
        .find(|path| is_executable(path))
}

fn command_candidates(home: Option<&Path>, name: &str) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(home) = home {
        candidates.push(home.join(".local/bin").join(name));
        candidates.push(home.join(".cargo/bin").join(name));
    }
    candidates.extend([
        PathBuf::from("/opt/homebrew/bin").join(name),
        PathBuf::from("/usr/local/bin").join(name),
        PathBuf::from("/usr/bin").join(name),
    ]);
    candidates
}

fn load_capture_environment(paths: &AppPaths) -> HashMap<String, String> {
    let allowed = [
        "DEEPGRAM_MODEL",
        "DEEPGRAM_LANG",
        "ELEVENLABS_LANG",
        "ARCO_AUDIO_BUFFER_SECONDS",
        "ARCO_MIC_DEVICE_ID",
        "ARCO_MIC_DEVICE_NAME",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "ALL_PROXY",
    ];
    let mut result = HashMap::new();
    // The legacy file is read as a compatibility bridge only. Its contents are
    // passed directly to the owned child process and are never copied or logged.
    for path in [
        paths.home.join(".claude/skills/arco/.env"),
        paths.app_data.join(".env"),
    ] {
        let Ok(contents) = fs::read_to_string(path) else {
            continue;
        };
        for line in contents.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let Some((key, value)) = line.split_once('=') else {
                continue;
            };
            let key = key.trim();
            if !allowed.contains(&key) {
                continue;
            }
            let value = value
                .trim()
                .trim_matches(|character| character == '\'' || character == '"');
            if !value.is_empty() {
                result.insert(key.to_string(), value.to_string());
            }
        }
    }
    for key in allowed {
        if let Ok(value) = std::env::var(key) {
            if !value.trim().is_empty() {
                result.insert(key.to_string(), value);
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_modes_are_explicit_and_closed() {
        for mode in ["both", "system", "mic"] {
            assert_eq!(validate_mode(mode), Ok(()));
        }
        assert!(validate_mode("").unwrap_err().contains("expected both"));
        assert!(validate_mode("both; echo unsafe")
            .unwrap_err()
            .contains("unsupported capture mode"));
    }

    #[test]
    fn finder_safe_tool_candidates_include_common_install_locations() {
        let home = Path::new("/Users/example");
        let candidates = command_candidates(Some(home), "swiftc");
        assert_eq!(
            candidates[0],
            PathBuf::from("/Users/example/.local/bin/swiftc")
        );
        assert!(candidates.contains(&PathBuf::from("/opt/homebrew/bin/swiftc")));
        assert!(candidates.contains(&PathBuf::from("/usr/local/bin/swiftc")));
        assert!(candidates.contains(&PathBuf::from("/usr/bin/swiftc")));
    }

    #[test]
    fn deepgram_runtime_is_a_bundled_rust_binary_not_a_script_runtime() {
        let paths = AppPaths {
            home: PathBuf::from("/Users/example"),
            app_data: PathBuf::from("/tmp/arco"),
            transcripts: PathBuf::from("/tmp/arco/transcripts"),
            notes: PathBuf::from("/tmp/arco/notes"),
            legacy_transcripts: PathBuf::from("/tmp/legacy"),
            native_dir: PathBuf::from("/Applications/Arco.app/Contents/Resources/native"),
        };
        let program = discover_deepgram_transcriber(&paths);
        assert_eq!(
            program.file_name().and_then(|value| value.to_str()),
            Some("arco-deepgram-transcriber")
        );
        assert!(!program.to_string_lossy().contains("python"));
        assert!(!program.to_string_lossy().contains("uv"));
    }

    #[test]
    fn bundled_native_recorder_exits_after_its_arco_parent_disappears() {
        let source = include_str!("../../native/recorder.swift");

        assert!(source.contains("ARCO_PARENT_PID"));
        assert!(source.contains("kill(parentPID, 0)"));
        assert!(source.contains("errno == ESRCH"));
        assert!(source.contains("Arco parent process exited"));
    }

    #[test]
    fn bundled_native_recorder_releases_every_core_audio_tap_resource() {
        let source = include_str!("../../native/recorder.swift");

        assert!(source.contains("installTerminationSignalHandler(SIGTERM)"));
        assert!(source.contains("DispatchSource.makeSignalSource("));
        assert!(source.contains("signal: signalNumber"));
        assert!(source.contains("signal(SIGPIPE, SIG_IGN)"));
        assert!(source.contains("private func stopCoreAudioTapCapture()"));
        assert!(source.contains("AudioDeviceStop("));
        assert!(source.contains("AudioDeviceDestroyIOProcID("));
        assert!(source.contains("AudioHardwareDestroyAggregateDevice("));
        assert!(source.contains("AudioHardwareDestroyProcessTap("));
    }

    #[test]
    fn startup_removes_only_stale_pipeline_ready_signals() {
        let root = tempfile::tempdir().unwrap();
        let recorder_signal = root.path().join("recorder-ready-old.signal");
        let transcriber_signal = root.path().join("transcriber-ready-old.signal");
        let regular_log = root.path().join("transcriber.log");
        let unrelated_signal = root.path().join("some-other-ready.signal");
        std::fs::write(&recorder_signal, b"ready").unwrap();
        std::fs::write(&transcriber_signal, b"ready").unwrap();
        std::fs::write(&regular_log, b"keep").unwrap();
        std::fs::write(&unrelated_signal, b"keep").unwrap();

        super::cleanup_stale_ready_signals(root.path()).unwrap();

        assert!(!recorder_signal.exists());
        assert!(!transcriber_signal.exists());
        assert!(regular_log.exists());
        assert!(unrelated_signal.exists());
    }
}
