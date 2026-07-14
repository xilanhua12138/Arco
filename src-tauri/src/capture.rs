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
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

const MAX_RECORDER_READY_TIMEOUT: Duration = Duration::from_secs(30);

fn pipeline_layout(transcription: &TranscriptionConfig) -> Vec<&'static str> {
    match (
        transcription.asr.provider.as_str(),
        transcription.diarization.provider.as_str(),
    ) {
        ("deepgram", "deepgram") => vec!["deepgram-combined"],
        ("local", "local") => vec!["local-combined"],
        ("deepgram", "local") => vec!["deepgram-asr", "local-diarization"],
        ("deepgram", "none") => vec!["deepgram-asr"],
        ("elevenlabs", "local") => vec!["elevenlabs-asr", "local-diarization"],
        ("elevenlabs", "deepgram") => {
            vec!["elevenlabs-asr", "deepgram-diarization"]
        }
        ("elevenlabs", "none") => vec!["elevenlabs-asr"],
        ("local", "deepgram") => vec!["local-asr", "deepgram-diarization"],
        ("local", "none") => vec!["local-asr"],
        _ => Vec::new(),
    }
}

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

#[derive(Clone, Debug, Default)]
pub struct CaptureSecrets {
    pub deepgram: Option<String>,
    pub elevenlabs: Option<String>,
}

#[derive(Clone, Debug)]
pub struct CaptureResume {
    pub meeting_id: String,
    pub transcript_path: PathBuf,
    pub started_at: String,
}

#[derive(Clone, Debug)]
struct ResolvedTranscriber {
    label: &'static str,
    definition: TranscriberDefinition,
    environment: HashMap<String, String>,
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
                    command: CommandSpec::new(program, Vec::new()),
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

struct TranscriberChild {
    label: &'static str,
    child: Child,
}

struct CaptureChildren {
    recorder: Child,
    transcribers: Vec<TranscriberChild>,
    _audio_pump: JoinHandle<()>,
    timeline: Option<PathBuf>,
}

struct PipelineReadySignals {
    recorder: PathBuf,
    transcribers: Vec<PathBuf>,
}

impl PipelineReadySignals {
    fn new(log_dir: &Path, suffix: &str, transcriber_count: usize) -> Self {
        let signals = Self {
            recorder: log_dir.join(format!("recorder-ready-{suffix}.signal")),
            transcribers: (0..transcriber_count)
                .map(|index| log_dir.join(format!("transcriber-ready-{suffix}-{index}.signal")))
                .collect(),
        };
        signals.clear();
        signals
    }

    fn clear(&self) {
        let _ = fs::remove_file(&self.recorder);
        for transcriber in &self.transcribers {
            let _ = fs::remove_file(transcriber);
        }
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
        self.start_with_transcription_and_secrets(mode, transcription, CaptureSecrets::default())
    }

    pub fn start_with_transcription_and_secrets(
        &self,
        mode: &str,
        transcription: TranscriptionConfig,
        secrets: CaptureSecrets,
    ) -> Result<CaptureState, String> {
        self.start_internal(mode, transcription, secrets, None)
    }

    pub fn resume_with_transcription_and_secrets(
        &self,
        mode: &str,
        transcription: TranscriptionConfig,
        secrets: CaptureSecrets,
        resume: CaptureResume,
    ) -> Result<CaptureState, String> {
        self.start_internal(mode, transcription, secrets, Some(resume))
    }

    fn start_internal(
        &self,
        mode: &str,
        transcription: TranscriptionConfig,
        secrets: CaptureSecrets,
        resume: Option<CaptureResume>,
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

        match self.spawn_pipeline(mode, &transcription, &secrets, resume.as_ref()) {
            Ok((children, transcript, started_at, id)) => {
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

        // Only these owned Child handles are touched. Arco never scans the global
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
        secrets: &CaptureSecrets,
        resume: Option<&CaptureResume>,
    ) -> Result<(CaptureChildren, PathBuf, String, String), String> {
        let destination = self
            .destination
            .lock()
            .map_err(|_| "transcript storage destination is unavailable".to_string())?
            .clone();
        let transcript_dir = destination.path;

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

        let now = Local::now();
        let session_started_at = now.to_rfc3339();
        let session_started_at_unix = format!("{:.3}", now.timestamp_millis() as f64 / 1_000.0);
        let suffix = format!("{}-{}", std::process::id(), now.timestamp_micros());
        let layout = pipeline_layout(transcription);
        if layout.is_empty() {
            return Err("the selected ASR and diarization providers cannot be composed".into());
        }
        let timeline = (layout.len() > 1).then(|| {
            self.config
                .log_dir
                .join(format!("speaker-timeline-{suffix}.json"))
        });
        let resolved = self.resolve_transcribers(transcription, timeline.as_deref())?;
        for transcriber in &resolved {
            if !is_executable(&transcriber.definition.command.program) {
                return Err(format!(
                    "{} runtime is not executable: {}",
                    transcriber.label,
                    transcriber.definition.command.program.display()
                ));
            }
            self.validate_credentials(&transcriber.definition, secrets)?;
        }
        let (transcript, active_meeting_id, capture_started_at) = if let Some(resume) = resume {
            prepare_transcript_for_resume(resume, &now)?;
            (
                resume.transcript_path.clone(),
                resume.meeting_id.clone(),
                resume.started_at.clone(),
            )
        } else {
            let transcript = create_transcript(
                &transcript_dir,
                &now.format("%Y%m%d-%H%M%S").to_string(),
                &now.format("%Y-%m-%d %H:%M:%S").to_string(),
            )?;
            let id = meeting_id(&destination.source, &transcript)?;
            (transcript, id, session_started_at)
        };

        let recorder_log = open_log(&self.config.log_dir.join("recorder.log"))?;
        let transcriber_log = open_log(&self.config.log_dir.join("transcriber.log"))?;
        let ready_signals =
            PipelineReadySignals::new(&self.config.log_dir, &suffix, resolved.len());
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
        let mut recorder = match recorder_command.spawn() {
            Ok(recorder) => recorder,
            Err(error) => {
                let _ = finalize_transcript(&transcript, "error");
                return Err(format!("could not start native recorder: {error}"));
            }
        };
        let recorder_stdout = match recorder.stdout.take() {
            Some(stdout) => stdout,
            None => {
                let _ = terminate_process_tree(&mut recorder, Duration::from_millis(250));
                let _ = finalize_transcript(&transcript, "error");
                return Err("native recorder did not expose its audio stream".into());
            }
        };

        let ready_timeouts: Vec<_> = resolved
            .iter()
            .map(|transcriber| transcriber.definition.ready_timeout)
            .collect();
        let mut transcribers = Vec::with_capacity(resolved.len());
        let mut inputs = Vec::with_capacity(resolved.len());
        for (index, transcriber) in resolved.into_iter().enumerate() {
            let mut command = Command::new(&transcriber.definition.command.program);
            command
                .args(&transcriber.definition.command.args)
                .arg(&transcript)
                .stdin(Stdio::piped())
                .stdout(Stdio::from(transcriber_log.try_clone().map_err(
                    |error| format!("could not clone transcriber log: {error}"),
                )?))
                .stderr(Stdio::from(transcriber_log.try_clone().map_err(
                    |error| format!("could not clone transcriber log: {error}"),
                )?))
                .envs(&self.config.environment)
                .envs(&transcriber.environment)
                .env("ARCO_READY_FILE", &ready_signals.transcribers[index])
                .env("ARCO_AUDIO_MODE", mode)
                .env("ARCO_SESSION_STARTED_AT_UNIX", &session_started_at_unix);
            apply_secret(&mut command, &transcriber.definition, secrets);
            if let Err(error) = configure_process_group(&mut command) {
                terminate_partial_pipeline(&mut recorder, &mut transcribers);
                let _ = finalize_transcript(&transcript, "error");
                return Err(format!(
                    "could not isolate {} process: {error}",
                    transcriber.label
                ));
            }
            let mut child = match command.spawn() {
                Ok(child) => child,
                Err(error) => {
                    terminate_partial_pipeline(&mut recorder, &mut transcribers);
                    let _ = finalize_transcript(&transcript, "error");
                    return Err(format!("could not start {}: {error}", transcriber.label));
                }
            };
            let Some(input) = child.stdin.take() else {
                let _ = terminate_process_tree(&mut child, Duration::from_millis(250));
                terminate_partial_pipeline(&mut recorder, &mut transcribers);
                let _ = finalize_transcript(&transcript, "error");
                return Err(format!(
                    "{} did not expose an audio input",
                    transcriber.label
                ));
            };
            inputs.push(input);
            transcribers.push(TranscriberChild {
                label: transcriber.label,
                child,
            });
        }

        let audio_pump = std::thread::Builder::new()
            .name("arco-audio-provider-fanout".into())
            .spawn(move || pump_audio(recorder_stdout, inputs))
            .map_err(|error| {
                terminate_partial_pipeline(&mut recorder, &mut transcribers);
                let _ = finalize_transcript(&transcript, "error");
                format!("could not start audio provider fan-out: {error}")
            })?;

        let mut children = CaptureChildren {
            recorder,
            transcribers,
            _audio_pump: audio_pump,
            timeline,
        };
        if self.config.requires_ready_signal {
            if let Err(error) = wait_for_pipeline_ready(
                &mut children,
                &ready_signals.recorder,
                &ready_signals.transcribers,
                &ready_timeouts,
            ) {
                terminate_recorder_then_transcriber(&mut children);
                let _ = finalize_transcript(&transcript, "error");
                return Err(error);
            }
        }

        Ok((children, transcript, capture_started_at, active_meeting_id))
    }

    fn resolve_transcribers(
        &self,
        transcription: &TranscriptionConfig,
        timeline: Option<&Path>,
    ) -> Result<Vec<ResolvedTranscriber>, String> {
        let local = || {
            self.config.transcribers.local.clone().ok_or_else(|| {
            "The on-device transcription runtime is not installed. Build or reinstall Arco to add local speech models."
                .to_string()
        })
        };
        let timeline_environment = || -> Result<HashMap<String, String>, String> {
            let path = timeline.ok_or_else(|| {
                "mixed ASR and diarization providers require a shared streaming timeline"
                    .to_string()
            })?;
            Ok(HashMap::from([(
                "ARCO_SPEAKER_TIMELINE_FILE".into(),
                path.to_string_lossy().into_owned(),
            )]))
        };
        let mut result = Vec::new();
        for label in pipeline_layout(transcription) {
            let resolved = match label {
                "deepgram-combined" | "deepgram-asr" | "deepgram-diarization" => {
                    let mut environment = HashMap::from([
                        (
                            "ARCO_TRANSCRIBER_ROLE".into(),
                            match label {
                                "deepgram-combined" => "combined",
                                "deepgram-diarization" => "diarization",
                                _ => "asr",
                            }
                            .into(),
                        ),
                        ("DEEPGRAM_MODEL".into(), "nova-3".into()),
                        ("DEEPGRAM_LANG".into(), transcription.asr.language.clone()),
                    ]);
                    if label != "deepgram-combined" && transcription.diarization.provider != "none"
                    {
                        environment.extend(timeline_environment()?);
                    }
                    ResolvedTranscriber {
                        label,
                        definition: self.config.transcribers.deepgram.clone(),
                        environment,
                    }
                }
                "elevenlabs-asr" => {
                    let mut environment = HashMap::from([(
                        "ELEVENLABS_LANG".into(),
                        transcription.asr.language.clone(),
                    )]);
                    if transcription.diarization.provider != "none" {
                        environment.extend(timeline_environment()?);
                    }
                    ResolvedTranscriber {
                        label,
                        definition: self.config.transcribers.elevenlabs.clone(),
                        environment,
                    }
                }
                "local-combined" | "local-asr" => {
                    let mut definition = local()?;
                    definition.command.args.extend([
                        OsString::from("stream"),
                        OsString::from("--model"),
                        OsString::from(&transcription.asr.model),
                        OsString::from("--language"),
                        OsString::from(&transcription.asr.language),
                        OsString::from("--diarization"),
                        OsString::from(if label == "local-combined" {
                            transcription.diarization.model.as_deref().unwrap_or("none")
                        } else {
                            "none"
                        }),
                    ]);
                    ResolvedTranscriber {
                        label,
                        definition,
                        environment: if transcription.diarization.provider == "deepgram" {
                            timeline_environment()?
                        } else {
                            HashMap::new()
                        },
                    }
                }
                "local-diarization" => {
                    let mut definition = local()?;
                    definition.command.args.extend([
                        OsString::from("diarize"),
                        OsString::from("--model"),
                        OsString::from(transcription.diarization.model.as_deref().ok_or_else(
                            || "local diarization requires a streaming model".to_string(),
                        )?),
                    ]);
                    ResolvedTranscriber {
                        label,
                        definition,
                        environment: timeline_environment()?,
                    }
                }
                _ => {
                    return Err(format!(
                        "unsupported transcription pipeline worker: {label}"
                    ))
                }
            };
            result.push(resolved);
        }
        Ok(result)
    }

    fn validate_credentials(
        &self,
        definition: &TranscriberDefinition,
        secrets: &CaptureSecrets,
    ) -> Result<(), String> {
        if definition.requires_deepgram_key
            && !credential_available(
                secrets.deepgram.as_deref(),
                "DEEPGRAM_API_KEY",
                &self.config.environment,
            )
        {
            return Err("Deepgram is not configured. Paste your API key in Arco Settings → Audio & speakers → Recognition.".into());
        }
        if definition.requires_elevenlabs_key
            && !credential_available(
                secrets.elevenlabs.as_deref(),
                "ELEVENLABS_API_KEY",
                &self.config.environment,
            )
        {
            return Err("ElevenLabs is not configured. Paste your API key in Arco Settings → Audio & speakers → Recognition.".into());
        }
        Ok(())
    }
}

fn credential_available(
    secret: Option<&str>,
    environment_key: &str,
    environment: &HashMap<String, String>,
) -> bool {
    secret.is_some_and(|value| !value.trim().is_empty())
        || environment
            .get(environment_key)
            .is_some_and(|value| !value.trim().is_empty())
        || std::env::var(environment_key)
            .map(|value| !value.trim().is_empty())
            .unwrap_or(false)
}

fn apply_secret(
    command: &mut Command,
    definition: &TranscriberDefinition,
    secrets: &CaptureSecrets,
) {
    if definition.requires_deepgram_key {
        if let Some(secret) = secrets
            .deepgram
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            command.env("DEEPGRAM_API_KEY", secret);
        }
    }
    if definition.requires_elevenlabs_key {
        if let Some(secret) = secrets
            .elevenlabs
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            command.env("ELEVENLABS_API_KEY", secret);
        }
    }
}

fn pump_audio<R: Read>(mut source: R, mut destinations: Vec<ChildStdin>) {
    let _ = fan_out_audio(&mut source, &mut destinations);
}

fn fan_out_audio<R: Read, W: Write>(source: &mut R, destinations: &mut [W]) -> std::io::Result<()> {
    let mut buffer = [0u8; 6_400];
    loop {
        let read = source.read(&mut buffer)?;
        if read == 0 {
            return Ok(());
        }
        for destination in destinations.iter_mut() {
            destination.write_all(&buffer[..read])?;
        }
    }
}

fn terminate_partial_pipeline(recorder: &mut Child, transcribers: &mut Vec<TranscriberChild>) {
    let _ = terminate_process_tree(recorder, Duration::from_millis(250));
    for transcriber in transcribers {
        let _ = terminate_process_tree(&mut transcriber.child, Duration::from_millis(250));
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
    transcriber_ready_files: &[PathBuf],
    transcriber_timeouts: &[Duration],
) -> Result<(), String> {
    let started = Instant::now();
    let recorder_timeout = transcriber_timeouts
        .iter()
        .copied()
        .max()
        .unwrap_or(MAX_RECORDER_READY_TIMEOUT)
        .min(MAX_RECORDER_READY_TIMEOUT);
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
        for transcriber in &mut children.transcribers {
            match transcriber.child.try_wait() {
                Ok(Some(status)) => {
                    return Err(format!(
                        "transcriber exited before readiness: {} ({status})",
                        transcriber.label,
                    ))
                }
                Err(error) => {
                    return Err(format!(
                        "could not inspect {} while starting: {error}",
                        transcriber.label
                    ))
                }
                Ok(None) => {}
            }
        }
        let recorder_ready = recorder_ready_file.is_file();
        let transcribers_ready = transcriber_ready_files.iter().all(|path| path.is_file());
        if recorder_ready && transcribers_ready {
            return Ok(());
        }
        if !recorder_ready && started.elapsed() >= recorder_timeout {
            return Err(format!(
                "native recorder did not become ready within {:.1} seconds",
                recorder_timeout.as_secs_f64()
            ));
        }
        for (index, ready_file) in transcriber_ready_files.iter().enumerate() {
            let timeout = transcriber_timeouts
                .get(index)
                .copied()
                .unwrap_or(Duration::from_secs(20));
            if !ready_file.is_file() && started.elapsed() >= timeout {
                let label = children
                    .transcribers
                    .get(index)
                    .map(|transcriber| transcriber.label)
                    .unwrap_or("live transcriber");
                return Err(format!(
                    "{label} did not become ready within {:.1} seconds",
                    timeout.as_secs_f64()
                ));
            }
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
    let mut failure = None;
    for transcriber in &mut children.transcribers {
        match transcriber.child.try_wait() {
            Err(error) => {
                failure = Some(format!("could not inspect {}: {error}", transcriber.label));
                break;
            }
            Ok(Some(status)) => {
                failure = Some(format!(
                    "transcriber exited unexpectedly: {} ({status})",
                    transcriber.label,
                ));
                break;
            }
            Ok(None) => {}
        }
    }
    if failure.is_none() {
        failure = match children.recorder.try_wait() {
            Err(error) => Some(format!("could not inspect native recorder: {error}")),
            Ok(Some(status)) => Some(format!("native recorder exited unexpectedly ({status})")),
            Ok(None) => None,
        };
    }
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

    for transcriber in &mut children.transcribers {
        match transcriber
            .child
            .wait_timeout(Duration::from_secs(2))
            .ok()
            .flatten()
        {
            Some(_) => {
                // A helper may exit before one of its descendants. Signal the
                // owned process group as a final sweep.
                let _ = terminate_process_tree(&mut transcriber.child, Duration::ZERO);
            }
            None => {
                let _ = terminate_process_tree(&mut transcriber.child, Duration::from_millis(500));
            }
        }
    }
    if let Some(timeline) = children.timeline.take() {
        let _ = fs::remove_file(timeline);
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

fn prepare_transcript_for_resume(
    resume: &CaptureResume,
    resumed_at: &chrono::DateTime<Local>,
) -> Result<(), String> {
    let (_, file_name) = resume
        .meeting_id
        .split_once(':')
        .ok_or_else(|| "invalid meeting id for capture resume".to_string())?;
    if file_name.is_empty()
        || resume
            .transcript_path
            .file_name()
            .and_then(|name| name.to_str())
            != Some(file_name)
    {
        return Err("capture resume meeting ID does not match its transcript".into());
    }
    chrono::DateTime::parse_from_rfc3339(&resume.started_at)
        .map_err(|_| "capture resume has an invalid original start time".to_string())?;
    let metadata = fs::symlink_metadata(&resume.transcript_path).map_err(|error| {
        format!(
            "could not open historical transcript {}: {error}",
            resume.transcript_path.display()
        )
    })?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err("historical transcript must be a regular non-symlink file".into());
    }
    if resume
        .transcript_path
        .extension()
        .and_then(|value| value.to_str())
        != Some("md")
    {
        return Err("historical transcript must be a Markdown file".into());
    }

    let mut file = OpenOptions::new()
        .append(true)
        .open(&resume.transcript_path)
        .map_err(|error| {
            format!(
                "could not continue historical transcript {}: {error}",
                resume.transcript_path.display()
            )
        })?;
    writeln!(
        file,
        "\n> Resumed: {} (live)\n",
        resumed_at.format("%Y-%m-%d %H:%M:%S")
    )
    .and_then(|_| file.flush())
    .map_err(|error| format!("could not mark historical transcript as resumed: {error}"))
}

fn finalize_live_marker(raw: String, outcome: &str) -> String {
    for (index, _) in raw.rmatch_indices(" (live)") {
        let line_start = raw[..index].rfind('\n').map_or(0, |position| position + 1);
        let line = &raw[line_start..index];
        if line.starts_with("> Started:") || line.starts_with("> Resumed:") {
            let mut finalized = raw;
            finalized.replace_range(index..index + " (live)".len(), &format!(" ({outcome})"));
            return finalized;
        }
    }
    raw
}

fn finalize_transcript(path: &Path, outcome: &str) -> Result<(), String> {
    let raw = fs::read_to_string(path)
        .map_err(|error| format!("could not read transcript while finalizing: {error}"))?;
    let raw = finalize_live_marker(raw, outcome);
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
        "ARCO_MIC_ECHO_CANCELLATION",
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
    fn capture_environment_allows_platform_aec_but_not_generic_denoise() {
        let root = tempfile::tempdir().unwrap();
        let app_data = root.path().join("app-data");
        std::fs::create_dir_all(&app_data).unwrap();
        std::fs::write(
            app_data.join(".env"),
            b"ARCO_MIC_ECHO_CANCELLATION=off\nARCO_NOISE_SUPPRESSION=on\n",
        )
        .unwrap();
        let paths = AppPaths {
            home: root.path().join("home"),
            app_data: app_data.clone(),
            transcripts: app_data.join("transcripts"),
            notes: app_data.join("notes"),
            legacy_transcripts: root.path().join("legacy"),
            native_dir: root.path().join("native"),
        };

        let environment = load_capture_environment(&paths);

        assert_eq!(
            environment
                .get("ARCO_MIC_ECHO_CANCELLATION")
                .map(String::as_str),
            Some("off")
        );
        assert_eq!(environment.get("ARCO_NOISE_SUPPRESSION"), None);
    }

    #[test]
    fn native_aec_contract_degrades_without_stopping_capture() {
        let source = include_str!("../../native/recorder.swift");

        assert!(source.contains("try input.setVoiceProcessingEnabled(true)"));
        assert!(source.contains("input.isVoiceProcessingAGCEnabled = false"));
        assert!(source.contains("echo cancellation unavailable; continuing raw"));
        assert!(source.contains("EchoCancellationPolicy.shouldEnable(mode: mode"));
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

    #[test]
    fn provider_pipeline_fuses_matching_engines_and_fans_out_mixed_engines() {
        let config = |asr: &str, diarization: &str| TranscriptionConfig {
            asr: crate::models::AsrConfig {
                provider: asr.into(),
                model: match asr {
                    "deepgram" => "nova-3",
                    "elevenlabs" => "scribe-v2-realtime",
                    _ => "whisper-small",
                }
                .into(),
                language: "auto".into(),
            },
            diarization: crate::models::DiarizationConfig {
                provider: diarization.into(),
                model: match diarization {
                    "deepgram" => Some("latest".into()),
                    "local" => Some("sortformer-streaming".into()),
                    _ => None,
                },
            },
        };

        assert_eq!(
            pipeline_layout(&config("deepgram", "deepgram")),
            ["deepgram-combined"]
        );
        assert_eq!(
            pipeline_layout(&config("local", "local")),
            ["local-combined"]
        );
        assert_eq!(
            pipeline_layout(&config("elevenlabs", "local")),
            ["elevenlabs-asr", "local-diarization"]
        );
        assert_eq!(
            pipeline_layout(&config("local", "deepgram")),
            ["local-asr", "deepgram-diarization"]
        );
        assert_eq!(
            pipeline_layout(&config("elevenlabs", "none")),
            ["elevenlabs-asr"]
        );
    }

    #[test]
    fn pcm_fanout_delivers_every_byte_to_each_provider_across_chunk_boundaries() {
        let payload: Vec<u8> = (0..12_804).map(|index| (index % 251) as u8).collect();
        let mut source = std::io::Cursor::new(payload.clone());
        let mut destinations = [Vec::new(), Vec::new()];

        fan_out_audio(&mut source, &mut destinations).unwrap();

        assert_eq!(destinations[0], payload);
        assert_eq!(destinations[1], payload);
    }

    #[test]
    fn mixed_pipeline_resolves_independent_commands_and_one_shared_timeline() {
        let definition = |requires_deepgram_key, requires_elevenlabs_key| TranscriberDefinition {
            command: CommandSpec::new(PathBuf::from("/bin/echo"), Vec::new()),
            requires_deepgram_key,
            requires_elevenlabs_key,
            ready_timeout: Duration::from_secs(20),
        };
        let manager = CaptureManager::new(CaptureConfig {
            transcript_dir: PathBuf::from("/tmp/transcripts"),
            log_dir: PathBuf::from("/tmp/logs"),
            recorder: RecorderSpec::Executable(PathBuf::from("/bin/echo")),
            transcribers: TranscriberCatalog {
                deepgram: definition(true, false),
                elevenlabs: definition(false, true),
                local: Some(definition(false, false)),
            },
            environment: HashMap::new(),
            requires_ready_signal: false,
        });
        let config = TranscriptionConfig {
            asr: crate::models::AsrConfig {
                provider: "elevenlabs".into(),
                model: "scribe-v2-realtime".into(),
                language: "zh-CN".into(),
            },
            diarization: crate::models::DiarizationConfig {
                provider: "local".into(),
                model: Some("pyannote-wespeaker-streaming".into()),
            },
        };
        let timeline = Path::new("/tmp/speaker-timeline.json");

        let resolved = manager
            .resolve_transcribers(&config, Some(timeline))
            .unwrap();

        assert_eq!(
            resolved
                .iter()
                .map(|worker| worker.label)
                .collect::<Vec<_>>(),
            vec!["elevenlabs-asr", "local-diarization"]
        );
        assert_eq!(
            resolved[0]
                .environment
                .get("ARCO_SPEAKER_TIMELINE_FILE")
                .map(String::as_str),
            Some("/tmp/speaker-timeline.json")
        );
        assert_eq!(
            resolved[1]
                .definition
                .command
                .args
                .iter()
                .map(|arg| arg.to_string_lossy().into_owned())
                .collect::<Vec<_>>(),
            vec!["diarize", "--model", "pyannote-wespeaker-streaming"]
        );
        assert!(resolved[0].definition.requires_elevenlabs_key);
        assert!(!resolved[1].definition.requires_elevenlabs_key);
    }
}
