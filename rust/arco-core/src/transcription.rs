use crate::capture::discover_local_transcriber;
use crate::models::{TranscriptionConfig, TranscriptionModelStatus};
use crate::paths::AppPaths;
use crate::process::{configure_process_group, terminate_process_tree};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};
use tempfile::NamedTempFile;

const MODEL_STATUS_TIMEOUT: Duration = Duration::from_secs(30);
const MODEL_PREPARE_TIMEOUT: Duration = Duration::from_secs(2 * 60 * 60);
const MODEL_WORKER_TERMINATION_GRACE: Duration = Duration::from_millis(100);
const MODEL_COMMAND_OUTPUT_LIMIT_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone, Debug)]
pub struct LocalTranscriptionRuntime {
    binary: Option<PathBuf>,
    model_dir: PathBuf,
}

impl LocalTranscriptionRuntime {
    pub fn discover(paths: &AppPaths) -> Self {
        Self {
            binary: discover_local_transcriber(paths),
            model_dir: paths.app_data.join("models"),
        }
    }

    pub fn statuses(&self) -> Result<Vec<TranscriptionModelStatus>, String> {
        self.run(&["models"])
    }

    pub fn validate_selection(&self, config: &TranscriptionConfig) -> Result<(), String> {
        config.validate()?;
        if config.asr.provider != "local" && config.diarization.provider != "local" {
            return Ok(());
        }
        let statuses = self.statuses().map_err(|error| {
            format!("Could not check the selected on-device transcription models: {error}")
        })?;
        validate_selected_models(config, &statuses)
    }

    pub fn prepare(&self, model: &str) -> Result<Vec<TranscriptionModelStatus>, String> {
        self.prepare_with_progress(model, |_| {})
    }

    pub fn prepare_with_progress<F>(
        &self,
        model: &str,
        mut on_progress: F,
    ) -> Result<Vec<TranscriptionModelStatus>, String>
    where
        F: FnMut(TranscriptionModelStatus),
    {
        validate_model(model, true)?;
        let args = ["prepare", "--model", model];
        let mut diagnostic_lines = Vec::new();
        let output = self.execute(
            &args,
            MODEL_PREPARE_TIMEOUT,
            |line| match serde_json::from_str::<TranscriptionModelStatus>(line) {
                Ok(status) => on_progress(status),
                Err(_) if !line.trim().is_empty() => diagnostic_lines.push(line.to_string()),
                Err(_) => {}
            },
        )?;
        if !output.status.success() {
            return Err(if diagnostic_lines.is_empty() {
                format!("local transcription runtime exited with {}", output.status)
            } else {
                diagnostic_lines.join("\n")
            });
        }
        serde_json::from_slice(&output.stdout).map_err(|error| {
            format!("local transcription runtime returned invalid status JSON: {error}")
        })
    }

    pub fn remove(&self, model: &str) -> Result<Vec<TranscriptionModelStatus>, String> {
        validate_model(model, true)?;
        self.run(&["remove", "--model", model])
    }

    fn run(&self, args: &[&str]) -> Result<Vec<TranscriptionModelStatus>, String> {
        let output = self.execute(args, MODEL_STATUS_TIMEOUT, |_| {})?;
        if !output.status.success() {
            let stderr = output.stderr.join("\n").trim().to_string();
            return Err(if stderr.is_empty() {
                format!("local transcription runtime exited with {}", output.status)
            } else {
                stderr
            });
        }
        serde_json::from_slice(&output.stdout).map_err(|error| {
            format!("local transcription runtime returned invalid status JSON: {error}")
        })
    }

    fn execute<F>(
        &self,
        args: &[&str],
        default_timeout: Duration,
        mut on_stderr: F,
    ) -> Result<LocalCommandOutput, String>
    where
        F: FnMut(&str),
    {
        let binary = self.binary.as_ref().ok_or_else(|| {
            "The on-device transcription runtime is not installed in this Arco build.".to_string()
        })?;
        let mut stdout_file = NamedTempFile::new()
            .map_err(|error| format!("could not create local model status buffer: {error}"))?;
        let stderr_file = NamedTempFile::new()
            .map_err(|error| format!("could not create local model progress buffer: {error}"))?;
        let stdout_sink = stdout_file
            .reopen()
            .map_err(|error| format!("could not open local model status buffer: {error}"))?;
        let stderr_sink = stderr_file
            .reopen()
            .map_err(|error| format!("could not open local model progress buffer: {error}"))?;
        let mut stderr_reader = stderr_file
            .reopen()
            .map_err(|error| format!("could not read local model progress buffer: {error}"))?;
        let mut command = Command::new(binary);
        command
            .args(args.iter().copied())
            .env("ARCO_MODEL_DIR", &self.model_dir)
            .env("ARCO_PARENT_PID", std::process::id().to_string())
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout_sink))
            .stderr(Stdio::from(stderr_sink));
        configure_process_group(&mut command)
            .map_err(|error| format!("could not isolate local transcription runtime: {error}"))?;
        let mut child = command
            .spawn()
            .map_err(|error| format!("could not start local transcription runtime: {error}"))?;

        let timeout = local_model_command_timeout(default_timeout);
        let output_limit = local_model_output_limit();
        let deadline = Instant::now() + timeout;
        let mut timed_out = false;
        let mut output_limit_hit = false;
        let mut wait_error = None;
        let mut stderr_lines = Vec::new();
        let mut stderr_pending = Vec::new();
        let mut stderr_bytes = 0usize;
        let status = loop {
            match drain_local_model_progress(
                &mut stderr_reader,
                &mut stderr_pending,
                &mut stderr_lines,
                &mut stderr_bytes,
                output_limit,
                false,
                &mut on_stderr,
            ) {
                Ok(true) => {
                    output_limit_hit = true;
                    match terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE) {
                        Ok(status) => break Some(status),
                        Err(error) => {
                            wait_error = Some(format!(
                                "local transcription runtime exceeded its output limit and cleanup failed: {error}"
                            ));
                            break None;
                        }
                    }
                }
                Ok(false) => {}
                Err(error) => {
                    let _ = terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE);
                    wait_error = Some(error);
                    break None;
                }
            }

            match stdout_file.as_file().metadata() {
                Ok(metadata) if metadata.len() > output_limit as u64 => {
                    output_limit_hit = true;
                    match terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE) {
                        Ok(status) => break Some(status),
                        Err(error) => {
                            wait_error = Some(format!(
                                "local transcription runtime exceeded its output limit and cleanup failed: {error}"
                            ));
                            break None;
                        }
                    }
                }
                Ok(_) => {}
                Err(error) => {
                    let _ = terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE);
                    wait_error = Some(format!(
                        "could not inspect local transcription status output: {error}"
                    ));
                    break None;
                }
            }

            match child.try_wait() {
                Ok(Some(_)) => {
                    match terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE) {
                        Ok(status) => break Some(status),
                        Err(error) => {
                            wait_error = Some(format!(
                                "could not clean up local transcription runtime: {error}"
                            ));
                            break None;
                        }
                    }
                }
                Ok(None) if Instant::now() >= deadline => {
                    timed_out = true;
                    match terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE) {
                        Ok(status) => break Some(status),
                        Err(error) => {
                            wait_error = Some(format!(
                                "local transcription runtime timed out and cleanup failed: {error}"
                            ));
                            break None;
                        }
                    }
                }
                Ok(None) => {}
                Err(error) => {
                    let _ = terminate_process_tree(&mut child, MODEL_WORKER_TERMINATION_GRACE);
                    wait_error = Some(format!(
                        "could not monitor local transcription runtime: {error}"
                    ));
                    break None;
                }
            }
            std::thread::sleep(Duration::from_millis(10));
        };

        if !output_limit_hit {
            output_limit_hit = drain_local_model_progress(
                &mut stderr_reader,
                &mut stderr_pending,
                &mut stderr_lines,
                &mut stderr_bytes,
                output_limit,
                true,
                &mut on_stderr,
            )?;
            let stdout_bytes = stdout_file
                .as_file()
                .metadata()
                .map_err(|error| {
                    format!("could not inspect local transcription status output: {error}")
                })?
                .len();
            if stdout_bytes > output_limit as u64 {
                output_limit_hit = true;
            }
        }

        if timed_out {
            return Err(format!(
                "local transcription runtime timed out after {} ms while running {}",
                timeout.as_millis(),
                args.join(" ")
            ));
        }
        if let Some(error) = wait_error {
            return Err(error);
        }
        if output_limit_hit {
            return Err(format!(
                "local transcription runtime exceeded the {}-byte output limit while running {}",
                output_limit,
                args.join(" ")
            ));
        }

        stdout_file
            .as_file_mut()
            .seek(SeekFrom::Start(0))
            .map_err(|error| format!("could not rewind local transcription status: {error}"))?;
        let mut stdout = Vec::new();
        stdout_file
            .as_file_mut()
            .read_to_end(&mut stdout)
            .map_err(|error| format!("could not read local transcription status: {error}"))?;

        Ok(LocalCommandOutput {
            status: status.ok_or_else(|| {
                "local transcription runtime ended without an exit status".to_string()
            })?,
            stdout,
            stderr: stderr_lines,
        })
    }
}

struct LocalCommandOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<String>,
}

fn local_model_command_timeout(default: Duration) -> Duration {
    std::env::var("ARCO_LOCAL_MODEL_COMMAND_TIMEOUT_MS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|milliseconds| *milliseconds > 0)
        .map(Duration::from_millis)
        .unwrap_or(default)
}

fn local_model_output_limit() -> usize {
    std::env::var("ARCO_LOCAL_MODEL_OUTPUT_LIMIT_BYTES")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .filter(|bytes| *bytes > 0)
        .unwrap_or(MODEL_COMMAND_OUTPUT_LIMIT_BYTES)
}

#[allow(clippy::too_many_arguments)]
fn drain_local_model_progress<F>(
    reader: &mut std::fs::File,
    pending: &mut Vec<u8>,
    lines: &mut Vec<String>,
    total_bytes: &mut usize,
    output_limit: usize,
    finalize: bool,
    on_line: &mut F,
) -> Result<bool, String>
where
    F: FnMut(&str),
{
    let mut chunk = [0u8; 8 * 1024];
    loop {
        let count = reader
            .read(&mut chunk)
            .map_err(|error| format!("could not read model download progress: {error}"))?;
        if count == 0 {
            break;
        }
        if total_bytes.saturating_add(count) > output_limit {
            return Ok(true);
        }
        *total_bytes += count;
        pending.extend_from_slice(&chunk[..count]);
        emit_complete_progress_lines(pending, lines, on_line);
    }

    if finalize && !pending.is_empty() {
        let line = String::from_utf8_lossy(pending)
            .trim_end_matches('\r')
            .to_string();
        pending.clear();
        on_line(&line);
        lines.push(line);
    }
    Ok(false)
}

fn emit_complete_progress_lines<F>(pending: &mut Vec<u8>, lines: &mut Vec<String>, on_line: &mut F)
where
    F: FnMut(&str),
{
    while let Some(newline) = pending.iter().position(|byte| *byte == b'\n') {
        let remainder = pending.split_off(newline + 1);
        let mut line_bytes = std::mem::replace(pending, remainder);
        line_bytes.pop();
        if line_bytes.last() == Some(&b'\r') {
            line_bytes.pop();
        }
        let line = String::from_utf8_lossy(&line_bytes).to_string();
        on_line(&line);
        lines.push(line);
    }
}

fn validate_selected_models(
    config: &TranscriptionConfig,
    statuses: &[TranscriptionModelStatus],
) -> Result<(), String> {
    let mut required = Vec::with_capacity(2);
    if config.asr.provider == "local" {
        required.push(config.asr.model.as_str());
    }
    if config.diarization.provider == "local" {
        required.push(
            config
                .diarization
                .model
                .as_deref()
                .ok_or_else(|| "local diarization requires a streaming model".to_string())?,
        );
    }
    for model in required {
        let ready = statuses
            .iter()
            .any(|status| status.id == model && status.installed && status.phase == "ready");
        if !ready {
            return Err(format!(
                "{} is selected but not installed. Open Arco Settings → Audio & speakers → Recognition, then choose Download & use.",
                local_model_label(model)
            ));
        }
    }
    Ok(())
}

fn local_model_label(model: &str) -> &str {
    match model {
        "nemotron-speech-3.5-streaming" => "Nemotron Speech 3.5",
        "whisper-tiny" => "Whisper Tiny",
        "whisper-base" => "Whisper Base",
        "whisper-small" => "Whisper Small",
        "whisper-medium" => "Whisper Medium",
        "whisper-large" => "Whisper Large",
        "sortformer-streaming" => "Streaming Sortformer",
        "pyannote-wespeaker-streaming" => "Pyannote + WeSpeaker",
        "lseend-ami-streaming" => "LS-EEND Meeting",
        "lseend-dihard3-streaming" => "LS-EEND General",
        _ => model,
    }
}

fn validate_model(model: &str, allow_diarizer: bool) -> Result<(), String> {
    const MODELS: &[&str] = &[
        "nemotron-speech-3.5-streaming",
        "whisper-tiny",
        "whisper-base",
        "whisper-small",
        "whisper-medium",
        "whisper-large",
    ];
    const DIARIZERS: &[&str] = &[
        "sortformer-streaming",
        "pyannote-wespeaker-streaming",
        "lseend-ami-streaming",
        "lseend-dihard3-streaming",
    ];
    if MODELS.contains(&model) || (allow_diarizer && DIARIZERS.contains(&model)) {
        Ok(())
    } else {
        Err(format!("unsupported local transcription model: {model}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    #[cfg(unix)]
    use std::time::{Duration, Instant};
    #[cfg(unix)]
    use tempfile::TempDir;

    #[test]
    fn model_management_rejects_cloud_and_unknown_ids() {
        assert!(validate_model("nova-3", false).is_err());
        assert!(validate_model("whisper-imaginary", false).is_err());
        assert!(validate_model("sortformer-streaming", true).is_ok());
        assert!(validate_model("whisper-large", false).is_ok());
    }

    #[test]
    fn model_management_accepts_only_known_local_diarizers() {
        for model in [
            "sortformer-streaming",
            "pyannote-wespeaker-streaming",
            "lseend-ami-streaming",
            "lseend-dihard3-streaming",
        ] {
            assert!(validate_model(model, true).is_ok(), "{model}");
        }
        assert!(validate_model("deepgram-diarization", true).is_err());
    }

    #[test]
    fn progress_lines_keep_nullable_fields_optional() {
        let parsed: TranscriptionModelStatus = serde_json::from_str(
            r#"{"id":"whisper-base","installed":false,"phase":"downloading","progress":0.25}"#,
        )
        .unwrap();
        assert_eq!(parsed.id, "whisper-base");
        assert_eq!(parsed.progress, Some(0.25));
        assert!(parsed.error.is_none());
        assert!(parsed.path.is_none());
    }

    #[test]
    fn selected_local_models_must_be_installed_before_capture_starts() {
        use crate::models::{AsrConfig, DiarizationConfig, TranscriptionConfig};

        let local = TranscriptionConfig {
            asr: AsrConfig {
                provider: "local".into(),
                model: "nemotron-speech-3.5-streaming".into(),
                language: "zh-CN".into(),
            },
            diarization: DiarizationConfig {
                provider: "local".into(),
                model: Some("sortformer-streaming".into()),
            },
        };
        let statuses = vec![
            TranscriptionModelStatus {
                id: "nemotron-speech-3.5-streaming".into(),
                installed: true,
                phase: "ready".into(),
                progress: Some(1.0),
                error: None,
                path: Some("/models/nemotron".into()),
            },
            TranscriptionModelStatus {
                id: "sortformer-streaming".into(),
                installed: false,
                phase: "not-installed".into(),
                progress: None,
                error: None,
                path: None,
            },
        ];

        let error = validate_selected_models(&local, &statuses).unwrap_err();
        assert_eq!(
            error,
            "Streaming Sortformer is selected but not installed. Open Arco Settings → Audio & speakers → Recognition, then choose Download & use."
        );

        let installed = statuses
            .iter()
            .cloned()
            .map(|mut status| {
                status.installed = true;
                status.phase = "ready".into();
                status
            })
            .collect::<Vec<_>>();
        assert_eq!(validate_selected_models(&local, &installed), Ok(()));

        let cloud = TranscriptionConfig::default();
        assert_eq!(validate_selected_models(&cloud, &[]), Ok(()));
    }

    #[cfg(unix)]
    #[serial_test::serial]
    #[test]
    fn model_status_timeout_terminates_the_entire_worker_process_group() {
        let root = TempDir::new().unwrap();
        let descendant_pid = root.path().join("descendant.pid");
        let worker = root.path().join("local-model-worker");
        std::fs::write(
            &worker,
            format!(
                "#!/bin/sh\necho \"$$\" > \"{}\"\n/bin/sh -c 'trap \"\" TERM HUP; /bin/sleep 5' &\nwait\nprintf '[]\\n'\n",
                descendant_pid.display()
            ),
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&worker, permissions).unwrap();

        let runtime = LocalTranscriptionRuntime {
            binary: Some(worker),
            model_dir: root.path().join("models"),
        };
        std::env::set_var("ARCO_LOCAL_MODEL_COMMAND_TIMEOUT_MS", "2000");
        let started = Instant::now();
        let result = runtime.statuses();
        std::env::remove_var("ARCO_LOCAL_MODEL_COMMAND_TIMEOUT_MS");

        let error = result.expect_err("a blocked model status worker must time out");
        assert!(error.contains("timed out"), "unexpected error: {error}");
        assert!(
            started.elapsed() < Duration::from_millis(2800),
            "timeout did not interrupt the worker promptly: {:?}",
            started.elapsed()
        );
        assert_process_disappears(&descendant_pid);
    }

    #[cfg(unix)]
    #[serial_test::serial]
    #[test]
    fn model_prepare_timeout_terminates_the_entire_worker_process_group() {
        let root = TempDir::new().unwrap();
        let descendant_pid = root.path().join("prepare-descendant.pid");
        let worker = root.path().join("local-model-worker");
        std::fs::write(
            &worker,
            format!(
                "#!/bin/sh\necho \"$$\" > \"{}\"\n/bin/sh -c 'trap \"\" TERM HUP; /bin/sleep 5' &\nwait\nprintf '[]\\n'\n",
                descendant_pid.display()
            ),
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&worker, permissions).unwrap();

        let runtime = LocalTranscriptionRuntime {
            binary: Some(worker),
            model_dir: root.path().join("models"),
        };
        std::env::set_var("ARCO_LOCAL_MODEL_COMMAND_TIMEOUT_MS", "2000");
        let started = Instant::now();
        let result = runtime.prepare("whisper-tiny");
        std::env::remove_var("ARCO_LOCAL_MODEL_COMMAND_TIMEOUT_MS");

        let error = result.expect_err("a blocked model preparation worker must time out");
        assert!(error.contains("timed out"), "unexpected error: {error}");
        assert!(
            started.elapsed() < Duration::from_millis(2800),
            "timeout did not interrupt model preparation promptly: {:?}",
            started.elapsed()
        );
        assert_process_disappears(&descendant_pid);
    }

    #[test]
    fn bundled_local_model_worker_exits_after_its_arco_parent_disappears() {
        let source = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../native/local-transcriber/Sources/ArcoLocalTranscriber/main.swift"),
        )
        .unwrap();
        assert!(source.contains("ARCO_PARENT_PID"));
        assert!(source.contains("kill(parentPID, 0)"));
        assert!(source.contains("Arco parent process exited"));
    }

    #[cfg(unix)]
    #[serial_test::serial]
    #[test]
    fn model_status_output_is_capped_before_it_can_exhaust_the_ui_process() {
        let root = TempDir::new().unwrap();
        let worker = root.path().join("local-model-worker");
        std::fs::write(
            &worker,
            "#!/bin/sh\n/usr/bin/yes x | /usr/bin/head -c 65536\n",
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&worker, permissions).unwrap();
        let runtime = LocalTranscriptionRuntime {
            binary: Some(worker),
            model_dir: root.path().join("models"),
        };

        std::env::set_var("ARCO_LOCAL_MODEL_OUTPUT_LIMIT_BYTES", "1024");
        let result = runtime.statuses();
        std::env::remove_var("ARCO_LOCAL_MODEL_OUTPUT_LIMIT_BYTES");

        let error = result.expect_err("oversized model worker output must be rejected");
        assert!(error.contains("output limit"), "unexpected error: {error}");
    }

    #[cfg(unix)]
    #[test]
    fn detached_pipe_holder_cannot_block_a_completed_model_command() {
        let root = TempDir::new().unwrap();
        let detached_pid = root.path().join("detached.pid");
        let worker = root.path().join("local-model-worker");
        std::fs::write(
            &worker,
            format!(
                "#!/bin/sh\n/usr/bin/perl -MPOSIX -e 'if (fork() == 0) {{ POSIX::setsid(); open(my $fh, \">\", \"{}\") or die; print $fh \"$$\"; close $fh; sleep 2; exit 0; }}'\nprintf '[]\\n'\n",
                detached_pid.display()
            ),
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&worker).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&worker, permissions).unwrap();
        let runtime = LocalTranscriptionRuntime {
            binary: Some(worker),
            model_dir: root.path().join("models"),
        };

        let started = Instant::now();
        let statuses = runtime.statuses().unwrap();
        let elapsed = started.elapsed();
        assert!(statuses.is_empty());
        assert!(
            elapsed < Duration::from_millis(800),
            "an inherited pipe blocked the completed command for {elapsed:?}"
        );

        if let Ok(pid) = std::fs::read_to_string(detached_pid) {
            if let Ok(pid) = pid.trim().parse::<i32>() {
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
    }

    #[cfg(unix)]
    fn assert_process_disappears(pid_file: &std::path::Path) {
        let deadline = Instant::now() + Duration::from_secs(1);
        while !pid_file.is_file() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        let pid = std::fs::read_to_string(pid_file)
            .expect("model worker did not report its PID")
            .trim()
            .parse::<i32>()
            .unwrap();
        while Instant::now() < deadline {
            let result = unsafe { libc::kill(pid, 0) };
            if result == -1 && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("model worker {pid} survived timeout cleanup");
    }
}
