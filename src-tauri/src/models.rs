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
pub struct TranscriptionConfig {
    pub provider: String,
    pub model: String,
    pub language: String,
    pub diarization: String,
}

impl Default for TranscriptionConfig {
    fn default() -> Self {
        Self {
            provider: "deepgram".into(),
            model: "nova-3".into(),
            language: "zh-CN".into(),
            diarization: "provider".into(),
        }
    }
}

impl TranscriptionConfig {
    pub fn validate(&self) -> Result<(), String> {
        match self.provider.as_str() {
            "deepgram" => {
                if self.model != "nova-3" || self.diarization != "provider" {
                    return Err("Deepgram requires model nova-3 with provider diarization".into());
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
                if !MODELS.contains(&self.model.as_str()) {
                    return Err(format!(
                        "unsupported local transcription model: {}",
                        self.model
                    ));
                }
                if !matches!(self.diarization.as_str(), "local-streaming" | "none") {
                    return Err(
                        "local transcription requires local-streaming or no diarization".into(),
                    );
                }
                if self.model == "nemotron-speech-3.5-streaming" && !cfg!(target_arch = "aarch64") {
                    return Err("Nemotron Speech 3.5 requires Apple Silicon".into());
                }
            }
            other => return Err(format!("unsupported transcription provider: {other}")),
        }
        if !matches!(self.language.as_str(), "auto" | "zh-CN" | "en-US") {
            return Err(format!(
                "unsupported transcription language: {}",
                self.language
            ));
        }
        Ok(())
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
pub struct AgentReply {
    pub provider: String,
    pub answer: String,
    pub sources: Vec<AgentSource>,
    pub created_at: String,
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
    pub context_scope: String,
    pub created_at: String,
    pub saved_as_note: bool,
    #[serde(default)]
    pub used_fallback: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_turn_id: Option<String>,
}
