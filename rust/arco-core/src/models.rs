use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingSummary {
    pub id: String,
    pub title: Option<String>,
    pub generated_summary: Option<String>,
    pub title_generation_status: String,
    pub summary_generation_status: String,
    pub started_at: String,
    pub duration_label: String,
    pub preview: String,
    pub path: String,
    pub utterance_count: usize,
    pub is_live: bool,
    pub source: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingArtifacts {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<GeneratedMeetingArtifact>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<GeneratedMeetingArtifact>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneratedMeetingArtifact {
    pub kind: String,
    pub status: String,
    pub value: Option<String>,
    pub provider: Option<String>,
    pub provider_session_id: Option<String>,
    pub provider_turn_id: Option<String>,
    pub error: Option<String>,
    pub updated_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptLine {
    pub id: String,
    pub timestamp: String,
    pub speaker: String,
    pub text: String,
    pub sequence: usize,
}

/// Display-only transcript text that has not reached the provider's second-pass
/// finalization boundary yet. The capture sidecar owns this snapshot; meeting
/// history never persists it into Markdown.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveTranscriptSnapshot {
    #[serde(default)]
    pub lines: Vec<LiveTranscriptLine>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveTranscriptLine {
    pub id: String,
    pub timestamp: String,
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MeetingDetail {
    pub summary: MeetingSummary,
    pub lines: Vec<TranscriptLine>,
    /// Kept for the local-agent adapter. The UI can ignore this field.
    pub raw_markdown: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LiveMeetingPoll {
    pub capture: CaptureState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revision: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub meeting: Option<MeetingDetail>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeStatus {
    pub provider: String,
    pub label: String,
    pub available: bool,
    pub path: Option<String>,
    pub version: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderConnectionTest {
    pub provider: String,
    pub ok: bool,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioSourceCheck {
    pub required: bool,
    pub ready: bool,
    pub level: Option<f32>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioSetupCheck {
    pub mode: String,
    pub success: bool,
    pub system: AudioSourceCheck,
    pub microphone: AudioSourceCheck,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptureState {
    pub phase: String,
    pub active_meeting_id: Option<String>,
    pub started_at: Option<String>,
    pub message: Option<String>,
    /// Extra fields make the native state useful to future settings UI without
    /// changing the four-field contract consumed by the first desktop client.
    pub mode: Option<String>,
    pub transcript_path: Option<String>,
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcription: Option<TranscriptionConfig>,
}

impl CaptureState {
    pub fn idle(message: impl Into<Option<String>>) -> Self {
        Self {
            phase: "idle".into(),
            active_meeting_id: None,
            started_at: None,
            message: message.into(),
            mode: None,
            transcript_path: None,
            error: None,
            transcription: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AsrConfig {
    pub provider: String,
    pub model: String,
    pub language: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiarizationConfig {
    pub provider: String,
    pub model: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptionConfig {
    pub asr: AsrConfig,
    pub diarization: DiarizationConfig,
}

impl Default for TranscriptionConfig {
    fn default() -> Self {
        Self {
            asr: AsrConfig {
                provider: "deepgram".into(),
                model: "nova-3".into(),
                language: "zh-CN".into(),
            },
            diarization: DiarizationConfig {
                provider: "deepgram".into(),
                model: Some("latest".into()),
            },
        }
    }
}

impl TranscriptionConfig {
    pub fn validate(&self) -> Result<(), String> {
        match self.asr.provider.as_str() {
            "deepgram" => {
                if self.asr.model != "nova-3" {
                    return Err("Deepgram ASR requires model nova-3".into());
                }
            }
            "elevenlabs" => {
                if self.asr.model != "scribe-v2-realtime" {
                    return Err("ElevenLabs ASR requires model scribe-v2-realtime".into());
                }
            }
            "doubao" => {
                if self.asr.model != "bigmodel" {
                    return Err("Doubao ASR requires model bigmodel".into());
                }
            }
            "local" => {
                const MODELS: &[&str] = &[
                    "nemotron-speech-3.5-streaming",
                    "whisper-tiny",
                    "whisper-base",
                    "whisper-small",
                    "whisper-medium",
                    "whisper-large",
                ];
                if !MODELS.contains(&self.asr.model.as_str()) {
                    return Err(format!(
                        "unsupported local transcription model: {}",
                        self.asr.model
                    ));
                }
                if self.asr.model == "nemotron-speech-3.5-streaming"
                    && !cfg!(target_arch = "aarch64")
                {
                    return Err("Nemotron Speech 3.5 requires Apple Silicon".into());
                }
            }
            other => return Err(format!("unsupported transcription provider: {other}")),
        }
        if !matches!(self.asr.language.as_str(), "auto" | "zh-CN" | "en-US") {
            return Err(format!(
                "unsupported transcription language: {}",
                self.asr.language
            ));
        }
        match (
            self.diarization.provider.as_str(),
            self.diarization.model.as_deref(),
        ) {
            ("deepgram", Some("latest")) => {}
            ("doubao", Some("bigmodel")) => {}
            (
                "local",
                Some(
                    "sortformer-streaming"
                    | "pyannote-wespeaker-streaming"
                    | "lseend-ami-streaming"
                    | "lseend-dihard3-streaming",
                ),
            ) => {}
            ("none", None) => {}
            ("deepgram", model) => {
                return Err(format!(
                    "Deepgram diarization requires model latest, got {}",
                    model.unwrap_or("none")
                ))
            }
            ("doubao", model) => {
                return Err(format!(
                    "Doubao diarization requires model bigmodel, got {}",
                    model.unwrap_or("none")
                ))
            }
            ("local", model) => {
                return Err(format!(
                    "unsupported local diarization model: {}",
                    model.unwrap_or("none")
                ))
            }
            ("none", Some(_)) => {
                return Err("disabled speaker diarization cannot select a model".into())
            }
            (other, _) => return Err(format!("unsupported diarization provider: {other}")),
        }
        Ok(())
    }
}

#[cfg(test)]
mod transcription_config_tests {
    use super::{AsrConfig, DiarizationConfig, TranscriptionConfig};

    fn local(diarization: &str) -> TranscriptionConfig {
        TranscriptionConfig {
            asr: AsrConfig {
                provider: "local".into(),
                model: "whisper-base".into(),
                language: "auto".into(),
            },
            diarization: if diarization == "none" {
                DiarizationConfig {
                    provider: "none".into(),
                    model: None,
                }
            } else {
                DiarizationConfig {
                    provider: "local".into(),
                    model: Some(diarization.into()),
                }
            },
        }
    }

    #[test]
    fn local_transcription_accepts_each_native_diarizer() {
        for diarization in [
            "sortformer-streaming",
            "pyannote-wespeaker-streaming",
            "lseend-ami-streaming",
            "lseend-dihard3-streaming",
            "none",
        ] {
            assert!(local(diarization).validate().is_ok(), "{diarization}");
        }
    }

    #[test]
    fn diarization_provider_rejects_a_model_from_another_provider() {
        let mut config = TranscriptionConfig::default();
        config.diarization.model = Some("lseend-ami-streaming".into());
        assert!(config.validate().is_err());

        assert!(local("latest").validate().is_err());
    }

    #[test]
    fn independent_provider_config_accepts_local_remote_streaming_mixes() {
        let remote_asr_local_diarization = serde_json::json!({
            "asr": {
                "provider": "elevenlabs",
                "model": "scribe-v2-realtime",
                "language": "auto"
            },
            "diarization": {
                "provider": "local",
                "model": "sortformer-streaming"
            }
        });
        let local_asr_remote_diarization = serde_json::json!({
            "asr": {
                "provider": "local",
                "model": "whisper-small",
                "language": "zh-CN"
            },
            "diarization": {
                "provider": "deepgram",
                "model": "latest"
            }
        });

        for value in [remote_asr_local_diarization, local_asr_remote_diarization] {
            let config: TranscriptionConfig = serde_json::from_value(value).unwrap();
            assert!(config.validate().is_ok());
        }
    }

    #[test]
    fn elevenlabs_requires_scribe_realtime_without_speaker_diarization() {
        let valid = TranscriptionConfig {
            asr: AsrConfig {
                provider: "elevenlabs".into(),
                model: "scribe-v2-realtime".into(),
                language: "auto".into(),
            },
            diarization: DiarizationConfig {
                provider: "none".into(),
                model: None,
            },
        };
        assert!(valid.validate().is_ok());

        let mut wrong_model = valid.clone();
        wrong_model.asr.model = "nova-3".into();
        assert!(wrong_model.validate().is_err());

        let mut wrong_diarizer = valid;
        wrong_diarizer.diarization.model = Some("latest".into());
        assert!(wrong_diarizer.validate().is_err());
    }

    #[test]
    fn doubao_requires_bigmodel_and_can_compose_with_independent_diarization() {
        let valid = TranscriptionConfig {
            asr: AsrConfig {
                provider: "doubao".into(),
                model: "bigmodel".into(),
                language: "zh-CN".into(),
            },
            diarization: DiarizationConfig {
                provider: "local".into(),
                model: Some("sortformer-streaming".into()),
            },
        };
        assert!(valid.validate().is_ok());

        let mut wrong_model = valid;
        wrong_model.asr.model = "nova-3".into();
        assert_eq!(
            wrong_model.validate(),
            Err("Doubao ASR requires model bigmodel".into())
        );

        let built_in = TranscriptionConfig {
            asr: AsrConfig {
                provider: "doubao".into(),
                model: "bigmodel".into(),
                language: "zh-CN".into(),
            },
            diarization: DiarizationConfig {
                provider: "doubao".into(),
                model: Some("bigmodel".into()),
            },
        };
        assert!(built_in.validate().is_ok());
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptionModelStatus {
    pub id: String,
    pub installed: bool,
    pub phase: String,
    #[serde(default)]
    pub progress: Option<f64>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSource {
    pub kind: String,
    pub label: String,
    pub reference: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentToolActivity {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentReply {
    pub provider: String,
    pub answer: String,
    pub sources: Vec<AgentSource>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_activities: Vec<AgentToolActivity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_duration_ms: Option<u64>,
    pub created_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentStreamEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    pub request_id: String,
    pub meeting_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub phase: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answer: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<AgentToolActivity>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentRunOutput {
    pub reply: AgentReply,
    pub provider_session_id: String,
    pub provider_turn_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSessionBinding {
    pub provider: String,
    pub session_id: String,
    pub context_scope: String,
    pub canonical_cwd: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersistedAgentTurn {
    pub id: String,
    pub meeting_id: String,
    pub provider: String,
    pub question: String,
    pub answer: String,
    pub sources: Vec<AgentSource>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_activities: Vec<AgentToolActivity>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub work_duration_ms: Option<u64>,
    pub context_scope: String,
    pub created_at: String,
    pub saved_as_note: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note_id: Option<String>,
    #[serde(default)]
    pub used_fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_turn_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedNote {
    pub meeting: MeetingSummary,
    pub turn: PersistedAgentTurn,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NoteDocument {
    pub id: String,
    pub title: String,
    pub body: String,
    pub source: String,
    pub created_at: String,
    pub updated_at: String,
    pub path: String,
    pub meeting_id: Option<String>,
    pub meeting_title: Option<String>,
    pub agent_turn_id: Option<String>,
}
