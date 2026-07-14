use crate::capture::discover_local_transcriber;
use crate::models::{TranscriptionConfig, TranscriptionModelStatus};
use crate::paths::AppPaths;
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::Command;

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
        self.run(["models"])
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
        let args = vec!["prepare", "--model", model];
        let binary = self.binary.as_ref().ok_or_else(|| {
            "The on-device transcription runtime is not installed in this Arco build.".to_string()
        })?;
        let mut child = Command::new(binary)
            .args(args)
            .env("ARCO_MODEL_DIR", &self.model_dir)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| format!("could not start local transcription runtime: {error}"))?;
        let stderr = child.stderr.take().ok_or_else(|| {
            "local transcription runtime did not expose progress output".to_string()
        })?;
        let mut diagnostic_lines = Vec::new();
        for line in BufReader::new(stderr).lines() {
            let line =
                line.map_err(|error| format!("could not read model download progress: {error}"))?;
            match serde_json::from_str::<TranscriptionModelStatus>(&line) {
                Ok(status) => on_progress(status),
                Err(_) if !line.trim().is_empty() => diagnostic_lines.push(line),
                Err(_) => {}
            }
        }
        let output = child
            .wait_with_output()
            .map_err(|error| format!("could not finish local model preparation: {error}"))?;
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
        self.run(["remove", "--model", model])
    }

    fn run<I, S>(&self, args: I) -> Result<Vec<TranscriptionModelStatus>, String>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        let binary = self.binary.as_ref().ok_or_else(|| {
            "The on-device transcription runtime is not installed in this Arco build.".to_string()
        })?;
        let output = Command::new(binary)
            .args(args)
            .env("ARCO_MODEL_DIR", &self.model_dir)
            .output()
            .map_err(|error| format!("could not start local transcription runtime: {error}"))?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
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
}
