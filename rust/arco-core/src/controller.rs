//! Framework-independent backend controller.
//!
//! This preserves the established desktop command payloads while making the
//! meeting, capture, Agent, storage, and credential logic usable by
//! a standalone SwiftUI application through a small C ABI.

use crate::agent::{self, AgentRunner, AgentStreamUpdate};
use crate::audio_setup::AudioSetupTester;
use crate::capture::{CaptureConfig, CaptureManager, CaptureResume, CaptureSecrets};
use crate::deepgram_credentials;
use crate::doubao_credentials;
use crate::elevenlabs_credentials;
use crate::meeting_output::{
    generate_meeting_output, list_meetings_with_artifacts, read_meeting_with_artifacts,
};
use crate::meeting_state::MeetingStateStore;
use crate::meetings::MeetingStore;
use crate::models::{AgentStreamEvent, TranscriptionConfig};
use crate::notes::{materialize_legacy_agent_notes, NoteStore, NotesStorage};
use crate::paths::AppPaths;
use crate::storage::TranscriptStorage;
use crate::transcription::LocalTranscriptionRuntime;
use serde::de::DeserializeOwned;
use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub trait EventSink: Send + Sync + 'static {
    fn emit(&self, name: &str, payload: Value);
}

#[derive(Default)]
pub struct NoopEventSink;

impl EventSink for NoopEventSink {
    fn emit(&self, _name: &str, _payload: Value) {}
}

pub struct Controller {
    meetings: MeetingStore,
    meeting_state: MeetingStateStore,
    capture: CaptureManager,
    audio_setup: AudioSetupTester,
    transcription: LocalTranscriptionRuntime,
    agent: AgentRunner,
    agent_run_lock: Mutex<()>,
    output_run_lock: Mutex<()>,
    storage: TranscriptStorage,
    storage_change_lock: Mutex<()>,
    notes: NoteStore,
    notes_storage: NotesStorage,
    notes_storage_change_lock: Mutex<()>,
    notes_change_lock: Mutex<()>,
    events: Arc<dyn EventSink>,
    runtime: tokio::runtime::Runtime,
}

impl Controller {
    pub fn new(paths: AppPaths, events: Arc<dyn EventSink>) -> Result<Self, String> {
        let agent_workspace = paths.app_data.join("agent-workspace");
        let storage = TranscriptStorage::load(paths.app_data.clone(), paths.transcripts.clone())?;
        let notes_storage = NotesStorage::load(paths.app_data.clone(), paths.notes.clone())?;
        let notes = NoteStore::new(notes_storage.note_roots())?;
        let meetings =
            MeetingStore::new(paths.transcripts.clone(), paths.legacy_transcripts.clone());
        meetings.set_roots(storage.meeting_roots())?;
        let capture = CaptureManager::new(CaptureConfig::discover(&paths));
        let audio_setup = AudioSetupTester::discover(&paths);
        capture.set_transcript_root(storage.active_root())?;
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|error| format!("could not start the Arco backend runtime: {error}"))?;
        Ok(Self {
            meetings,
            meeting_state: MeetingStateStore::new(paths.app_data.join("meeting-state")),
            capture,
            audio_setup,
            transcription: LocalTranscriptionRuntime::discover(&paths),
            agent: AgentRunner::new(agent_workspace),
            agent_run_lock: Mutex::new(()),
            output_run_lock: Mutex::new(()),
            storage,
            storage_change_lock: Mutex::new(()),
            notes,
            notes_storage,
            notes_storage_change_lock: Mutex::new(()),
            notes_change_lock: Mutex::new(()),
            events,
            runtime,
        })
    }

    pub fn dispatch(&self, command: &str, params: Value) -> Result<Value, String> {
        match command {
            "storage_settings" => value(self.storage.settings()),
            "set_transcript_directory" => {
                let directory = optional::<String>(&params, "directory")?;
                value(self.set_transcript_directory(directory)?)
            }
            "notes_storage_settings" => value(self.notes_storage.settings()),
            "set_notes_directory" => {
                let directory = optional::<String>(&params, "directory")?;
                value(self.set_notes_directory(directory)?)
            }
            "list_notes" => value(self.list_notes(optional::<String>(&params, "query")?)?),
            "save_note" => value(self.save_note(
                optional::<String>(&params, "noteId")?,
                required(&params, "meetingId")?,
                required(&params, "title")?,
                required(&params, "body")?,
            )?),
            "delete_note" => {
                self.delete_note(required(&params, "noteId")?)?;
                Ok(Value::Null)
            }
            "list_meetings" => value(self.list_meetings(optional::<String>(&params, "query")?)?),
            "read_meeting" => value(self.read_meeting(required(&params, "id")?)?),
            "poll_live_meeting" => value(self.poll_live_meeting(
                required(&params, "meetingId")?,
                optional::<String>(&params, "knownRevision")?,
            )?),
            "rename_meeting" => value(self.rename_meeting(
                required(&params, "meetingId")?,
                optional::<String>(&params, "title")?,
            )?),
            "list_agent_turns" => value(self.list_agent_turns(required(&params, "meetingId")?)?),
            "list_attachments" => value(
                self.meeting_state
                    .list_attachments(&required::<String>(&params, "meetingId")?)?,
            ),
            "add_attachment" => {
                let meeting_id = required::<String>(&params, "meetingId")?;
                let attachments = self.meeting_state.add_attachment(
                    &meeting_id,
                    &required::<String>(&params, "name")?,
                    &required::<String>(&params, "text")?,
                )?;
                self.emit("arco:agent-attachments-changed", &meeting_id);
                value(attachments)
            }
            "remove_attachment" => {
                let meeting_id = required::<String>(&params, "meetingId")?;
                let attachments = self.meeting_state.remove_attachment(
                    &meeting_id,
                    &required::<String>(&params, "attachmentId")?,
                )?;
                self.emit("arco:agent-attachments-changed", &meeting_id);
                value(attachments)
            }
            "list_saved_notes" => {
                value(self.list_saved_notes(optional::<String>(&params, "query")?)?)
            }
            "set_agent_turn_saved" => value(self.set_agent_turn_saved(
                required(&params, "meetingId")?,
                required(&params, "turnId")?,
                required(&params, "saved")?,
            )?),
            "runtime_status" => value(agent::runtime_statuses()),
            "test_agent_provider" => value(
                self.agent
                    .test_provider(&required::<String>(&params, "provider")?),
            ),
            "deepgram_credential_status" => value(deepgram_credentials::status()),
            "save_deepgram_api_key" => {
                value(deepgram_credentials::save_verified_api_key(&required::<
                    String,
                >(
                    &params, "apiKey",
                )?)?)
            }
            "remove_deepgram_api_key" => value(deepgram_credentials::remove_api_key()?),
            "elevenlabs_credential_status" => value(elevenlabs_credentials::status()),
            "save_elevenlabs_api_key" => {
                value(elevenlabs_credentials::save_verified_api_key(&required::<
                    String,
                >(
                    &params, "apiKey",
                )?)?)
            }
            "remove_elevenlabs_api_key" => value(elevenlabs_credentials::remove_api_key()?),
            "doubao_credential_status" => value(doubao_credentials::status()),
            "save_doubao_credentials" => value(self.runtime.block_on(
                doubao_credentials::save_verified_credentials(
                    &required::<String>(&params, "appId")?,
                    &required::<String>(&params, "accessToken")?,
                ),
            )?),
            "remove_doubao_credentials" => value(doubao_credentials::remove_credentials()?),
            "capture_status" => value(self.capture.status()),
            "test_audio_setup" => value(
                self.audio_setup
                    .clone()
                    .test(&required::<String>(&params, "mode")?)?,
            ),
            "transcription_model_status" => value(self.transcription.statuses()?),
            "prepare_transcription_model" => {
                let model = required::<String>(&params, "model")?;
                let events = self.events.clone();
                value(
                    self.transcription
                        .prepare_with_progress(&model, move |status| {
                            events.emit(
                                "arco:transcription-model-progress",
                                serde_json::to_value(status).unwrap_or(Value::Null),
                            );
                        })?,
                )
            }
            "remove_transcription_model" => value(
                self.transcription
                    .remove(&required::<String>(&params, "model")?)?,
            ),
            "start_capture" => value(self.start_capture(
                required(&params, "mode")?,
                optional::<TranscriptionConfig>(&params, "transcription")?,
                optional::<String>(&params, "meetingId")?,
            )?),
            "stop_capture" => value(self.stop_capture()?),
            "run_agent" => value(self.run_agent(
                required(&params, "provider")?,
                optional::<bool>(&params, "usedFallback")?.unwrap_or(false),
                required(&params, "question")?,
                optional::<String>(&params, "agentPrompt")?,
                required(&params, "meetingId")?,
                optional::<String>(&params, "contextScope")?,
                optional::<String>(&params, "workspace")?,
                required(&params, "requestId")?,
            )?),
            "generate_meeting_output" => value(self.generate_meeting_output(
                required(&params, "provider")?,
                required(&params, "meetingId")?,
                required(&params, "kind")?,
                required(&params, "prompt")?,
                optional::<bool>(&params, "regenerate")?.unwrap_or(false),
            )?),
            other => Err(format!("unknown backend command: {other}")),
        }
    }

    fn emit<T: Serialize>(&self, name: &str, payload: T) {
        self.events.emit(
            name,
            serde_json::to_value(payload)
                .unwrap_or_else(|error| json!({ "serializationError": error.to_string() })),
        );
    }

    fn set_transcript_directory(
        &self,
        directory: Option<String>,
    ) -> Result<crate::storage::TranscriptStorageSettings, String> {
        let _guard = self
            .storage_change_lock
            .lock()
            .map_err(|_| "transcript storage coordinator is unavailable".to_string())?;
        if matches!(
            self.capture.status().phase.as_str(),
            "starting" | "recording" | "stopping"
        ) {
            return Err("stop the current meeting before changing transcript storage".into());
        }
        let settings = self
            .storage
            .select_directory(directory.as_deref().map(Path::new))?;
        self.meetings.set_roots(self.storage.meeting_roots())?;
        self.capture
            .set_transcript_root(self.storage.active_root())?;
        self.emit("arco:storage-changed", &settings);
        Ok(settings)
    }

    fn set_notes_directory(
        &self,
        directory: Option<String>,
    ) -> Result<crate::notes::NotesStorageSettings, String> {
        let _guard = self
            .notes_storage_change_lock
            .lock()
            .map_err(|_| "notes storage coordinator is unavailable".to_string())?;
        let _notes_guard = self
            .notes_change_lock
            .lock()
            .map_err(|_| "notes coordinator is unavailable".to_string())?;
        let settings = self
            .notes_storage
            .select_directory(directory.as_deref().map(Path::new))?;
        self.notes.set_roots(self.notes_storage.note_roots())?;
        self.emit("arco:notes-storage-changed", &settings);
        Ok(settings)
    }

    fn list_notes(
        &self,
        query: Option<String>,
    ) -> Result<Vec<crate::models::NoteDocument>, String> {
        let _guard = self
            .notes_change_lock
            .lock()
            .map_err(|_| "notes coordinator is unavailable".to_string())?;
        let active = self.capture.active_transcript_path();
        let meetings = list_meetings_with_artifacts(
            &self.meetings,
            &self.meeting_state,
            None,
            active.as_deref(),
        )?;
        materialize_legacy_agent_notes(
            &self.notes,
            &self.notes_storage,
            &self.meeting_state,
            &meetings,
        )?;
        let mut notes = self.notes.list(query.as_deref())?;
        for note in &mut notes {
            if let Some(meeting) = note
                .meeting_id
                .as_deref()
                .and_then(|id| meetings.iter().find(|meeting| meeting.id == id))
            {
                note.meeting_title = meeting.title.clone();
            }
        }
        Ok(notes)
    }

    fn save_note(
        &self,
        note_id: Option<String>,
        meeting_id: String,
        title: String,
        body: String,
    ) -> Result<crate::models::NoteDocument, String> {
        let _guard = self
            .notes_change_lock
            .lock()
            .map_err(|_| "notes coordinator is unavailable".to_string())?;
        let active = self.capture.active_transcript_path();
        let mut meeting = self.meetings.read(&meeting_id, active.as_deref())?.summary;
        self.meeting_state.hydrate_meeting_summary(&mut meeting)?;
        let note = self.notes.save_manual(
            &self.notes_storage.active_root(),
            note_id.as_deref(),
            &meeting,
            &title,
            &body,
        )?;
        self.emit("arco:notes-changed", &note.id);
        Ok(note)
    }

    fn delete_note(&self, note_id: String) -> Result<(), String> {
        let _guard = self
            .notes_change_lock
            .lock()
            .map_err(|_| "notes coordinator is unavailable".to_string())?;
        let note = self.notes.read(&note_id)?;
        self.notes.delete(&note_id)?;
        if let (Some(meeting_id), Some(turn_id)) = (note.meeting_id, note.agent_turn_id) {
            self.meeting_state
                .link_saved_note(&meeting_id, &turn_id, None)?;
            self.emit("arco:agent-thread-changed", &meeting_id);
        }
        self.emit("arco:notes-changed", &note_id);
        Ok(())
    }

    fn list_meetings(
        &self,
        query: Option<String>,
    ) -> Result<Vec<crate::models::MeetingSummary>, String> {
        let active = self.capture.active_transcript_path();
        list_meetings_with_artifacts(
            &self.meetings,
            &self.meeting_state,
            query.as_deref(),
            active.as_deref(),
        )
    }

    fn read_meeting(&self, id: String) -> Result<crate::models::MeetingDetail, String> {
        let active = self.capture.active_transcript_path();
        read_meeting_with_artifacts(&self.meetings, &self.meeting_state, &id, active.as_deref())
    }

    fn poll_live_meeting(
        &self,
        meeting_id: String,
        known_revision: Option<String>,
    ) -> Result<crate::models::LiveMeetingPoll, String> {
        let capture = self.capture.status();
        if capture.phase != "recording"
            || capture.active_meeting_id.as_deref() != Some(meeting_id.as_str())
        {
            return Ok(crate::models::LiveMeetingPoll {
                capture,
                revision: None,
                meeting: None,
            });
        }

        let active = self.capture.active_transcript_path();
        let (revision, mut meeting) = self.meetings.read_if_changed(
            &meeting_id,
            known_revision.as_deref(),
            active.as_deref(),
        )?;
        if let Some(detail) = meeting.as_mut() {
            self.meeting_state
                .hydrate_meeting_summary(&mut detail.summary)?;
        }
        Ok(crate::models::LiveMeetingPoll {
            capture,
            revision: Some(revision),
            meeting,
        })
    }

    fn rename_meeting(
        &self,
        meeting_id: String,
        title: Option<String>,
    ) -> Result<crate::models::MeetingSummary, String> {
        let active = self.capture.active_transcript_path();
        let mut detail = self.meetings.read(&meeting_id, active.as_deref())?;
        self.meeting_state
            .set_manual_title(&meeting_id, title.as_deref())?;
        self.meeting_state
            .hydrate_meeting_summary(&mut detail.summary)?;
        self.emit("arco:meeting-output-changed", &meeting_id);
        Ok(detail.summary)
    }

    fn list_agent_turns(
        &self,
        meeting_id: String,
    ) -> Result<Vec<crate::models::PersistedAgentTurn>, String> {
        let active = self.capture.active_transcript_path();
        self.meetings.read(&meeting_id, active.as_deref())?;
        self.meeting_state.list(&meeting_id)
    }

    fn list_saved_notes(
        &self,
        query: Option<String>,
    ) -> Result<Vec<crate::models::SavedNote>, String> {
        let active = self.capture.active_transcript_path();
        let meetings = list_meetings_with_artifacts(
            &self.meetings,
            &self.meeting_state,
            None,
            active.as_deref(),
        )?;
        self.meeting_state
            .list_saved_notes(&meetings, query.as_deref())
    }

    fn set_agent_turn_saved(
        &self,
        meeting_id: String,
        turn_id: String,
        saved: bool,
    ) -> Result<crate::models::PersistedAgentTurn, String> {
        let _guard = self
            .notes_change_lock
            .lock()
            .map_err(|_| "notes coordinator is unavailable".to_string())?;
        let active = self.capture.active_transcript_path();
        let mut meeting = self.meetings.read(&meeting_id, active.as_deref())?.summary;
        self.meeting_state.hydrate_meeting_summary(&mut meeting)?;
        let current = self
            .meeting_state
            .list(&meeting_id)?
            .into_iter()
            .find(|turn| turn.id == turn_id)
            .ok_or_else(|| format!("agent turn not found for meeting {meeting_id}: {turn_id}"))?;
        let turn = if saved {
            if current
                .note_id
                .as_deref()
                .is_some_and(|note_id| self.notes.read(note_id).is_ok())
            {
                current
            } else {
                let note =
                    self.notes
                        .save_agent(&self.notes_storage.active_root(), &meeting, &current)?;
                match self
                    .meeting_state
                    .link_saved_note(&meeting_id, &turn_id, Some(&note.id))
                {
                    Ok(turn) => turn,
                    Err(error) => {
                        let _ = self.notes.delete(&note.id);
                        return Err(error);
                    }
                }
            }
        } else {
            if let Some(note_id) = current.note_id.as_deref() {
                if self.notes.read(note_id).is_ok() {
                    self.notes.delete(note_id)?;
                }
            }
            self.meeting_state
                .link_saved_note(&meeting_id, &turn_id, None)?
        };
        self.emit("arco:agent-thread-changed", &meeting_id);
        self.emit("arco:notes-changed", turn.note_id.as_deref());
        Ok(turn)
    }

    fn start_capture(
        &self,
        mode: String,
        transcription: Option<TranscriptionConfig>,
        meeting_id: Option<String>,
    ) -> Result<crate::models::CaptureState, String> {
        let _storage_guard = self
            .storage_change_lock
            .lock()
            .map_err(|_| "transcript storage coordinator is unavailable".to_string())?;
        let transcription = transcription.unwrap_or_default();
        self.transcription.validate_selection(&transcription)?;
        let secrets = CaptureSecrets {
            deepgram: if transcription.asr.provider == "deepgram"
                || transcription.diarization.provider == "deepgram"
            {
                deepgram_credentials::load_api_key()?
            } else {
                None
            },
            elevenlabs: if transcription.asr.provider == "elevenlabs" {
                elevenlabs_credentials::load_api_key()?
            } else {
                None
            },
            doubao: if transcription.asr.provider == "doubao"
                || transcription.diarization.provider == "doubao"
            {
                doubao_credentials::load_credentials()?
            } else {
                None
            },
        };
        let resume = if let Some(meeting_id) = meeting_id {
            let active = self.capture.active_transcript_path();
            let detail = self.meetings.read(&meeting_id, active.as_deref())?;
            Some(CaptureResume {
                meeting_id,
                transcript_path: PathBuf::from(&detail.summary.path),
                started_at: detail.summary.started_at,
            })
        } else {
            None
        };
        let resumed_meeting_id = resume.as_ref().map(|target| target.meeting_id.clone());
        let capture = if let Some(resume) = resume {
            self.capture.resume_with_transcription_and_secrets(
                &mode,
                transcription,
                secrets,
                resume,
            )?
        } else {
            self.capture
                .start_with_transcription_and_secrets(&mode, transcription, secrets)?
        };
        if let Some(meeting_id) = resumed_meeting_id.as_deref() {
            if let Err(error) = self.meeting_state.invalidate_generated_summary(meeting_id) {
                log::warn!(
                    "Arco continued meeting {meeting_id} but could not invalidate its old summary: {error}"
                );
            }
        }
        self.emit("arco:capture-changed", &capture);
        Ok(capture)
    }

    fn stop_capture(&self) -> Result<crate::models::CaptureState, String> {
        let result = self.capture.stop();
        self.emit("arco:capture-changed", self.capture.status());
        result
    }

    #[allow(clippy::too_many_arguments)]
    fn run_agent(
        &self,
        provider: String,
        used_fallback: bool,
        question: String,
        agent_prompt: Option<String>,
        meeting_id: String,
        context_scope: Option<String>,
        workspace: Option<String>,
        request_id: String,
    ) -> Result<crate::models::PersistedAgentTurn, String> {
        let question = question.trim().to_string();
        if question.is_empty() {
            return Err("question cannot be empty".to_string());
        }
        let request_id = request_id.trim().to_string();
        if request_id.is_empty()
            || request_id.len() > 128
            || request_id.chars().any(char::is_control)
        {
            return Err("invalid Agent request ID".to_string());
        }
        let agent_prompt = agent_prompt
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(question.as_str());
        let _run_guard = self
            .agent_run_lock
            .lock()
            .map_err(|_| "agent session coordinator is unavailable".to_string())?;
        let active = self.capture.active_transcript_path();
        let mut meeting = self.meetings.read(&meeting_id, active.as_deref())?;
        meeting.attachments = self.meeting_state.list_attachments(&meeting_id)?;
        let workspace = workspace
            .map(|value| value.trim().to_string())
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let context_scope = context_scope.as_deref().unwrap_or("transcript");
        let canonical_cwd = self
            .agent
            .working_directory(context_scope, workspace.as_deref())?;
        let binding = self.meeting_state.session_binding(
            &meeting_id,
            &provider,
            context_scope,
            &canonical_cwd,
        )?;
        let expected_session_id = binding.as_ref().map(|binding| binding.session_id.as_str());
        self.emit(
            "arco:agent-stream",
            AgentStreamEvent {
                event_type: "status".into(),
                request_id: request_id.clone(),
                meeting_id: meeting_id.clone(),
                phase: Some("starting".into()),
                answer: None,
                tool: None,
            },
        );
        let events = self.events.clone();
        let stream_request_id = request_id.clone();
        let stream_meeting_id = meeting_id.clone();
        let output = self.agent.run_session_streamed(
            &provider,
            agent_prompt,
            &meeting,
            context_scope,
            workspace.as_deref(),
            expected_session_id,
            move |update| {
                let event = match update {
                    AgentStreamUpdate::Phase(phase) => AgentStreamEvent {
                        event_type: "status".into(),
                        request_id: stream_request_id.clone(),
                        meeting_id: stream_meeting_id.clone(),
                        phase: Some(phase.into()),
                        answer: None,
                        tool: None,
                    },
                    AgentStreamUpdate::Answer(answer) => AgentStreamEvent {
                        event_type: "answer".into(),
                        request_id: stream_request_id.clone(),
                        meeting_id: stream_meeting_id.clone(),
                        phase: None,
                        answer: Some(answer),
                        tool: None,
                    },
                    AgentStreamUpdate::Tool(tool) => AgentStreamEvent {
                        event_type: "tool".into(),
                        request_id: stream_request_id.clone(),
                        meeting_id: stream_meeting_id.clone(),
                        phase: None,
                        answer: None,
                        tool: Some(tool),
                    },
                };
                events.emit(
                    "arco:agent-stream",
                    serde_json::to_value(event).unwrap_or(Value::Null),
                );
            },
        )?;
        let turn = self.meeting_state.commit_agent_turn(
            &meeting_id,
            &question,
            context_scope,
            &canonical_cwd,
            &output,
            used_fallback,
            expected_session_id,
        )?;
        self.emit("arco:agent-thread-changed", &meeting_id);
        Ok(turn)
    }

    fn generate_meeting_output(
        &self,
        provider: String,
        meeting_id: String,
        kind: String,
        prompt: String,
        regenerate: bool,
    ) -> Result<crate::models::GeneratedMeetingArtifact, String> {
        let active = self.capture.active_transcript_path();
        let artifact = generate_meeting_output(
            &self.output_run_lock,
            &self.agent,
            &self.meetings,
            &self.meeting_state,
            &provider,
            &meeting_id,
            &kind,
            &prompt,
            active.as_deref(),
            regenerate,
        )?;
        self.emit("arco:meeting-output-changed", &meeting_id);
        Ok(artifact)
    }
}

impl Drop for Controller {
    fn drop(&mut self) {
        self.capture.shutdown();
    }
}

fn value<T: Serialize>(value: T) -> Result<Value, String> {
    serde_json::to_value(value)
        .map_err(|error| format!("could not encode backend response: {error}"))
}

fn required<T: DeserializeOwned>(params: &Value, key: &str) -> Result<T, String> {
    let value = params
        .get(key)
        .ok_or_else(|| format!("missing backend argument: {key}"))?;
    serde_json::from_value(value.clone())
        .map_err(|error| format!("invalid backend argument {key}: {error}"))
}

fn optional<T: DeserializeOwned>(params: &Value, key: &str) -> Result<Option<T>, String> {
    let Some(value) = params.get(key) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    serde_json::from_value(value.clone())
        .map(Some)
        .map_err(|error| format!("invalid backend argument {key}: {error}"))
}
