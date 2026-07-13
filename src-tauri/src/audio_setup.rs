use crate::models::{AudioSetupCheck, AudioSourceCheck};
use crate::paths::AppPaths;
use crate::process::{configure_process_group, terminate_process_tree};
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use tempfile::NamedTempFile;
use wait_timeout::ChildExt;

const DEFAULT_TEST_DURATION: Duration = Duration::from_secs(3);
const TERMINATION_GRACE: Duration = Duration::from_millis(250);
const MAX_CAPTURE_BYTES: usize = 16_000 * 4 * 5;
const READY_LEVEL: f32 = 0.01;
const RESTART_REQUIRED_PREFIX: &str = "ARCO_AUDIO_PERMISSION_RESTART_REQUIRED:";

#[derive(Clone, Debug)]
pub struct AudioSetupTester {
    recorder: PathBuf,
    duration: Duration,
}

impl AudioSetupTester {
    pub fn discover(paths: &AppPaths) -> Self {
        let bundled = paths.native_dir.join("recorder");
        let runtime = paths.native_dir.join("runtime").join("recorder");
        let recorder = if bundled.exists() { bundled } else { runtime };
        Self::with_binary(recorder, DEFAULT_TEST_DURATION)
    }

    pub fn with_binary(recorder: PathBuf, duration: Duration) -> Self {
        Self { recorder, duration }
    }

    pub fn test(&self, mode: &str) -> Result<AudioSetupCheck, String> {
        validate_mode(mode)?;
        if !is_executable(&self.recorder) {
            return Err(format!(
                "Arco audio recorder is not executable: {}",
                self.recorder.display()
            ));
        }

        let stderr_file = NamedTempFile::new()
            .map_err(|error| format!("could not create audio check error buffer: {error}"))?;
        let mut command = Command::new(&self.recorder);
        command
            .arg(mode)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(stderr_file.reopen().map_err(|error| {
                format!("could not open audio check error buffer: {error}")
            })?));
        configure_process_group(&mut command)
            .map_err(|error| format!("could not isolate audio check process: {error}"))?;
        let mut child = command
            .spawn()
            .map_err(|error| format!("failed to start {}: {error}", self.recorder.display()))?;
        let mut stdout = child
            .stdout
            .take()
            .ok_or_else(|| "audio recorder did not expose its PCM stream".to_string())?;
        let (sender, receiver) = mpsc::channel::<Vec<u8>>();
        let reader = thread::spawn(move || {
            let mut buffer = [0u8; 8_192];
            loop {
                match stdout.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(size) => {
                        if sender.send(buffer[..size].to_vec()).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        let started = Instant::now();
        let mut bytes = Vec::new();
        let mut early_status = None;
        while started.elapsed() < self.duration {
            while let Ok(chunk) = receiver.try_recv() {
                let remaining = MAX_CAPTURE_BYTES.saturating_sub(bytes.len());
                bytes.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
            }
            match child.try_wait() {
                Ok(Some(status)) => {
                    early_status = Some(status);
                    break;
                }
                Ok(None) => thread::sleep(Duration::from_millis(15)),
                Err(error) => {
                    let _ = terminate_process_tree(&mut child, TERMINATION_GRACE);
                    let _ = reader.join();
                    return Err(format!("could not wait for audio recorder: {error}"));
                }
            }
        }

        if early_status.is_none() {
            early_status = child
                .try_wait()
                .map_err(|error| format!("could not finish audio check: {error}"))?;
        }
        if early_status.is_none() {
            // A short-lived permission failure can race the final poll. Give
            // it one last chance to return its real exit code before Arco's
            // intentional TERM would replace that status with a signal.
            early_status = child
                .wait_timeout(Duration::from_millis(100))
                .map_err(|error| format!("could not finish audio check: {error}"))?;
        }
        if early_status.is_none() {
            let status = terminate_process_tree(&mut child, TERMINATION_GRACE)
                .map_err(|error| format!("could not stop audio check: {error}"))?;
            // A real recorder failure can race the final poll. Preserve an
            // ordinary exit code, while ignoring the signal Arco intentionally
            // sends to end a healthy finite-duration probe.
            if status.code().is_some() && !status.success() {
                early_status = Some(status);
            }
        } else {
            let _ = terminate_process_tree(&mut child, TERMINATION_GRACE);
        }
        let _ = reader.join();
        while let Ok(chunk) = receiver.try_recv() {
            let remaining = MAX_CAPTURE_BYTES.saturating_sub(bytes.len());
            bytes.extend_from_slice(&chunk[..chunk.len().min(remaining)]);
        }

        if let Some(status) = early_status {
            if !status.success() {
                let detail = fs::read_to_string(stderr_file.path()).unwrap_or_default();
                let code = status
                    .code()
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "signal".into());
                return Err(format_recorder_error(&code, detail.trim()));
            }
        }

        analyze_interleaved_pcm(mode, &bytes)
    }
}

fn format_recorder_error(code: &str, detail: &str) -> String {
    let message = if detail.is_empty() {
        format!("audio recorder exited with status {code}")
    } else {
        format!("audio recorder exited with status {code}: {detail}")
    };
    let normalized = detail.to_ascii_lowercase();
    let screen_capture_permission = normalized.contains("screen recording permission")
        || normalized.contains("no display is available")
        || (normalized.contains("screencapturekit.scstreamerrordomain")
            && normalized.contains("code=-3801"))
        || (normalized.contains("screencapturekit") && normalized.contains("tcc"))
        || (normalized.contains("shareable content")
            && (normalized.contains("permission") || normalized.contains("not authorized")));
    if screen_capture_permission {
        format!("{RESTART_REQUIRED_PREFIX} {message}")
    } else {
        message
    }
}

pub fn analyze_interleaved_pcm(mode: &str, bytes: &[u8]) -> Result<AudioSetupCheck, String> {
    validate_mode(mode)?;
    if bytes.len() % 4 != 0 {
        return Err("audio recorder returned malformed stereo PCM".into());
    }
    let mut system_energy = 0f64;
    let mut microphone_energy = 0f64;
    let frames = bytes.len() / 4;
    for frame in bytes.chunks_exact(4) {
        let system = i16::from_le_bytes([frame[0], frame[1]]) as f64 / i16::MAX as f64;
        let microphone = i16::from_le_bytes([frame[2], frame[3]]) as f64 / i16::MAX as f64;
        system_energy += system * system;
        microphone_energy += microphone * microphone;
    }
    let divisor = frames.max(1) as f64;
    let system_level = (system_energy / divisor).sqrt().min(1.0) as f32;
    let microphone_level = (microphone_energy / divisor).sqrt().min(1.0) as f32;
    let system_required = mode != "mic";
    let microphone_required = mode != "system";
    let system_ready = !system_required || system_level >= READY_LEVEL;
    let microphone_ready = !microphone_required || microphone_level >= READY_LEVEL;

    Ok(AudioSetupCheck {
        mode: mode.into(),
        success: system_ready && microphone_ready,
        system: AudioSourceCheck {
            required: system_required,
            ready: system_ready,
            level: Some(system_level),
            message: None,
        },
        microphone: AudioSourceCheck {
            required: microphone_required,
            ready: microphone_ready,
            level: Some(microphone_level),
            message: None,
        },
    })
}

fn validate_mode(mode: &str) -> Result<(), String> {
    if ["both", "system", "mic"].contains(&mode) {
        Ok(())
    } else {
        Err(format!("invalid audio mode: {mode}"))
    }
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        path.metadata()
            .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}
