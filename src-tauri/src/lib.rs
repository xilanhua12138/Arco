pub mod agent;
pub mod audio_setup;
pub mod capture;
pub mod deepgram;
mod deepgram_credentials;
#[cfg(target_os = "macos")]
mod dock_icon;
pub mod doubao;
pub mod doubao_credentials;
pub mod elevenlabs;
mod elevenlabs_credentials;
mod listening_shortcut;
mod material;
pub mod meeting_output;
pub mod meeting_state;
pub mod meetings;
pub mod models;
mod native_action;
mod native_glass;
mod native_notes_toolbar;
mod native_search;
mod native_shell;
mod native_surface;
pub mod notes;
mod overlay;
pub mod paths;
pub mod process;
pub mod speaker_timeline;
pub mod storage;
pub mod transcription;

#[cfg(all(test, target_os = "macos"))]
mod dock_icon_contract_tests {
    #[test]
    fn dock_icon_decodes_at_the_app_icon_master_size() {
        let image = crate::dock_icon::load().expect("Arco app icon should decode");
        let size = image.size();
        assert_eq!(size.width, 1254.0);
        assert_eq!(size.height, 1254.0);
    }

    #[test]
    fn dock_icon_has_white_rounded_tile_and_dark_mark() {
        let bitmap = crate::dock_icon::load_bitmap().expect("Dock bitmap should decode");

        let corner = bitmap
            .colorAtX_y(0, 0)
            .expect("corner pixel should be readable");
        let white_tile = bitmap
            .colorAtX_y(160, 160)
            .expect("tile pixel should be readable");
        let dark_mark = bitmap
            .colorAtX_y(627, 627)
            .expect("mark pixel should be readable");

        assert!(
            corner.alphaComponent() < 0.01,
            "outer corner must be transparent"
        );
        assert!(white_tile.alphaComponent() > 0.99, "tile must be opaque");
        assert!(white_tile.redComponent() > 0.97, "tile must be white");
        assert!(white_tile.greenComponent() > 0.97, "tile must be white");
        assert!(white_tile.blueComponent() > 0.97, "tile must be white");
        assert!(
            dark_mark.redComponent() < 0.25,
            "Arco mark must remain dark"
        );
        assert!(
            dark_mark.greenComponent() < 0.25,
            "Arco mark must remain dark"
        );
        assert!(
            dark_mark.blueComponent() < 0.25,
            "Arco mark must remain dark"
        );
    }
}

use agent::{AgentRunner, AgentStreamUpdate};
use audio_setup::AudioSetupTester;
use capture::{CaptureConfig, CaptureManager, CaptureResume, CaptureSecrets};
use deepgram_credentials::DeepgramCredentialStatus;
use doubao_credentials::DoubaoCredentialStatus;
use elevenlabs_credentials::ElevenLabsCredentialStatus;
use meeting_output::{
    generate_meeting_output_once, list_meetings_with_artifacts, read_meeting_with_artifacts,
};
use meeting_state::MeetingStateStore;
use meetings::MeetingStore;
use models::{
    AgentStreamEvent, AudioSetupCheck, CaptureState, GeneratedMeetingArtifact, MeetingDetail,
    MeetingSummary, NoteDocument, PersistedAgentTurn, ProviderConnectionTest, RuntimeStatus,
    SavedNote, TranscriptionConfig, TranscriptionModelStatus,
};
use native_action::NativeActionButtonState;
use native_notes_toolbar::NativeNotesToolbarState;
use native_search::NativeSearchFieldState;
use native_shell::NativeShellState;
use native_surface::NativeGlassSurfaceState;
use notes::{materialize_legacy_agent_notes, NoteStore, NotesStorage, NotesStorageSettings};
use paths::AppPaths;
use std::path::PathBuf;
use std::sync::Mutex;
use storage::{TranscriptStorage, TranscriptStorageSettings};
use tauri::ipc::Channel;
use tauri::{Emitter, Manager};
use tauri_plugin_opener::OpenerExt;
use transcription::LocalTranscriptionRuntime;

pub struct AppState {
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
}

impl AppState {
    pub fn new(paths: AppPaths) -> Result<Self, String> {
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
        })
    }
}

#[tauri::command(async)]
fn storage_settings(state: tauri::State<'_, AppState>) -> TranscriptStorageSettings {
    state.storage.settings()
}

#[tauri::command(async)]
fn set_transcript_directory(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    directory: Option<String>,
) -> Result<TranscriptStorageSettings, String> {
    let _guard = state
        .storage_change_lock
        .lock()
        .map_err(|_| "transcript storage coordinator is unavailable".to_string())?;
    if matches!(
        state.capture.status().phase.as_str(),
        "starting" | "recording" | "stopping"
    ) {
        return Err("stop the current meeting before changing transcript storage".into());
    }
    let settings = state
        .storage
        .select_directory(directory.as_deref().map(std::path::Path::new))?;
    state.meetings.set_roots(state.storage.meeting_roots())?;
    state
        .capture
        .set_transcript_root(state.storage.active_root())?;
    let _ = app.emit("arco:storage-changed", &settings);
    Ok(settings)
}

#[tauri::command(async)]
fn notes_storage_settings(state: tauri::State<'_, AppState>) -> NotesStorageSettings {
    state.notes_storage.settings()
}

#[tauri::command(async)]
fn set_notes_directory(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    directory: Option<String>,
) -> Result<NotesStorageSettings, String> {
    let _guard = state
        .notes_storage_change_lock
        .lock()
        .map_err(|_| "notes storage coordinator is unavailable".to_string())?;
    let _notes_guard = state
        .notes_change_lock
        .lock()
        .map_err(|_| "notes coordinator is unavailable".to_string())?;
    let settings = state
        .notes_storage
        .select_directory(directory.as_deref().map(std::path::Path::new))?;
    state.notes.set_roots(state.notes_storage.note_roots())?;
    let _ = app.emit("arco:notes-storage-changed", &settings);
    Ok(settings)
}

#[tauri::command(async)]
fn list_notes(
    state: tauri::State<'_, AppState>,
    query: Option<String>,
) -> Result<Vec<NoteDocument>, String> {
    let _guard = state
        .notes_change_lock
        .lock()
        .map_err(|_| "notes coordinator is unavailable".to_string())?;
    let active = state.capture.active_transcript_path();
    let meetings = list_meetings_with_artifacts(
        &state.meetings,
        &state.meeting_state,
        None,
        active.as_deref(),
    )?;

    // v3 and older sidecars only stored a boolean. Materialize those saved
    // Agent answers as regular Markdown files the first time Notes opens.
    materialize_legacy_agent_notes(
        &state.notes,
        &state.notes_storage,
        &state.meeting_state,
        &meetings,
    )?;

    let mut notes = state.notes.list(query.as_deref())?;
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

#[tauri::command(async)]
fn save_note(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    note_id: Option<String>,
    meeting_id: String,
    title: String,
    body: String,
) -> Result<NoteDocument, String> {
    let _guard = state
        .notes_change_lock
        .lock()
        .map_err(|_| "notes coordinator is unavailable".to_string())?;
    let active = state.capture.active_transcript_path();
    let mut meeting = state.meetings.read(&meeting_id, active.as_deref())?.summary;
    state.meeting_state.hydrate_meeting_summary(&mut meeting)?;
    let note = state.notes.save_manual(
        &state.notes_storage.active_root(),
        note_id.as_deref(),
        &meeting,
        &title,
        &body,
    )?;
    let _ = app.emit("arco:notes-changed", &note.id);
    Ok(note)
}

#[tauri::command(async)]
fn delete_note(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    note_id: String,
) -> Result<(), String> {
    let _guard = state
        .notes_change_lock
        .lock()
        .map_err(|_| "notes coordinator is unavailable".to_string())?;
    let note = state.notes.read(&note_id)?;
    state.notes.delete(&note_id)?;
    if let (Some(meeting_id), Some(turn_id)) = (note.meeting_id, note.agent_turn_id) {
        state
            .meeting_state
            .link_saved_note(&meeting_id, &turn_id, None)?;
        let _ = app.emit("arco:agent-thread-changed", &meeting_id);
    }
    let _ = app.emit("arco:notes-changed", &note_id);
    Ok(())
}

#[tauri::command(async)]
fn list_meetings(
    state: tauri::State<'_, AppState>,
    query: Option<String>,
) -> Result<Vec<MeetingSummary>, String> {
    let active = state.capture.active_transcript_path();
    list_meetings_with_artifacts(
        &state.meetings,
        &state.meeting_state,
        query.as_deref(),
        active.as_deref(),
    )
}

#[tauri::command(async)]
fn read_meeting(state: tauri::State<'_, AppState>, id: String) -> Result<MeetingDetail, String> {
    let active = state.capture.active_transcript_path();
    read_meeting_with_artifacts(
        &state.meetings,
        &state.meeting_state,
        &id,
        active.as_deref(),
    )
}

#[tauri::command(async)]
fn rename_meeting(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    meeting_id: String,
    title: Option<String>,
) -> Result<MeetingSummary, String> {
    let active = state.capture.active_transcript_path();
    // Resolve the transcript before touching its sidecar so a fabricated ID
    // cannot create orphaned meeting state.
    let mut detail = state.meetings.read(&meeting_id, active.as_deref())?;
    state
        .meeting_state
        .set_manual_title(&meeting_id, title.as_deref())?;
    state
        .meeting_state
        .hydrate_meeting_summary(&mut detail.summary)?;
    let _ = app.emit("arco:meeting-output-changed", &meeting_id);
    Ok(detail.summary)
}

#[tauri::command(async)]
fn list_agent_turns(
    state: tauri::State<'_, AppState>,
    meeting_id: String,
) -> Result<Vec<PersistedAgentTurn>, String> {
    let active = state.capture.active_transcript_path();
    state.meetings.read(&meeting_id, active.as_deref())?;
    state.meeting_state.list(&meeting_id)
}

#[tauri::command(async)]
fn list_saved_notes(
    state: tauri::State<'_, AppState>,
    query: Option<String>,
) -> Result<Vec<SavedNote>, String> {
    let active = state.capture.active_transcript_path();
    let meetings = list_meetings_with_artifacts(
        &state.meetings,
        &state.meeting_state,
        None,
        active.as_deref(),
    )?;
    state
        .meeting_state
        .list_saved_notes(&meetings, query.as_deref())
}

#[tauri::command(async)]
fn set_agent_turn_saved(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    meeting_id: String,
    turn_id: String,
    saved: bool,
) -> Result<PersistedAgentTurn, String> {
    let _guard = state
        .notes_change_lock
        .lock()
        .map_err(|_| "notes coordinator is unavailable".to_string())?;
    let active = state.capture.active_transcript_path();
    let mut meeting = state.meetings.read(&meeting_id, active.as_deref())?.summary;
    state.meeting_state.hydrate_meeting_summary(&mut meeting)?;
    let current = state
        .meeting_state
        .list(&meeting_id)?
        .into_iter()
        .find(|turn| turn.id == turn_id)
        .ok_or_else(|| format!("agent turn not found for meeting {meeting_id}: {turn_id}"))?;
    let turn = if saved {
        if current
            .note_id
            .as_deref()
            .is_some_and(|note_id| state.notes.read(note_id).is_ok())
        {
            current
        } else {
            let note =
                state
                    .notes
                    .save_agent(&state.notes_storage.active_root(), &meeting, &current)?;
            match state
                .meeting_state
                .link_saved_note(&meeting_id, &turn_id, Some(&note.id))
            {
                Ok(turn) => turn,
                Err(error) => {
                    let _ = state.notes.delete(&note.id);
                    return Err(error);
                }
            }
        }
    } else {
        if let Some(note_id) = current.note_id.as_deref() {
            if state.notes.read(note_id).is_ok() {
                state.notes.delete(note_id)?;
            }
        }
        state
            .meeting_state
            .link_saved_note(&meeting_id, &turn_id, None)?
    };
    let _ = app.emit("arco:agent-thread-changed", &meeting_id);
    let _ = app.emit("arco:notes-changed", turn.note_id.as_deref());
    Ok(turn)
}

#[tauri::command(async)]
fn runtime_status() -> Vec<RuntimeStatus> {
    agent::runtime_statuses()
}

#[tauri::command(async)]
fn test_agent_provider(
    state: tauri::State<'_, AppState>,
    provider: String,
) -> ProviderConnectionTest {
    state.agent.test_provider(&provider)
}

#[tauri::command(async)]
fn deepgram_credential_status() -> DeepgramCredentialStatus {
    deepgram_credentials::status()
}

#[tauri::command]
async fn save_deepgram_api_key(api_key: String) -> Result<DeepgramCredentialStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        deepgram_credentials::save_verified_api_key(&api_key)
    })
    .await
    .map_err(|error| format!("could not verify the Deepgram credential: {error}"))?
}

#[tauri::command(async)]
fn remove_deepgram_api_key() -> Result<DeepgramCredentialStatus, String> {
    deepgram_credentials::remove_api_key()
}

#[tauri::command(async)]
fn open_deepgram_console(app: tauri::AppHandle) -> Result<(), String> {
    app.opener()
        .open_url("https://console.deepgram.com/", None::<&str>)
        .map_err(|error| format!("Could not open the Deepgram console: {error}"))
}

#[tauri::command(async)]
fn elevenlabs_credential_status() -> ElevenLabsCredentialStatus {
    elevenlabs_credentials::status()
}

#[tauri::command]
async fn save_elevenlabs_api_key(api_key: String) -> Result<ElevenLabsCredentialStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        elevenlabs_credentials::save_verified_api_key(&api_key)
    })
    .await
    .map_err(|error| format!("could not verify the ElevenLabs credential: {error}"))?
}

#[tauri::command(async)]
fn remove_elevenlabs_api_key() -> Result<ElevenLabsCredentialStatus, String> {
    elevenlabs_credentials::remove_api_key()
}

#[tauri::command(async)]
fn open_elevenlabs_console(app: tauri::AppHandle) -> Result<(), String> {
    app.opener()
        .open_url(
            "https://elevenlabs.io/app/developers/api-keys",
            None::<&str>,
        )
        .map_err(|error| format!("Could not open the ElevenLabs API keys page: {error}"))
}

#[tauri::command(async)]
fn doubao_credential_status() -> DoubaoCredentialStatus {
    doubao_credentials::status()
}

#[tauri::command]
async fn save_doubao_credentials(
    app_id: String,
    access_token: String,
) -> Result<DoubaoCredentialStatus, String> {
    doubao_credentials::save_verified_credentials(&app_id, &access_token).await
}

#[tauri::command(async)]
fn remove_doubao_credentials() -> Result<DoubaoCredentialStatus, String> {
    doubao_credentials::remove_credentials()
}

#[tauri::command(async)]
fn open_doubao_console(app: tauri::AppHandle) -> Result<(), String> {
    app.opener()
        .open_url("https://console.volcengine.com/speech/app", None::<&str>)
        .map_err(|error| format!("Could not open the Volcengine Speech console: {error}"))
}

#[tauri::command(async)]
fn capture_status(state: tauri::State<'_, AppState>) -> CaptureState {
    state.capture.status()
}

#[tauri::command]
async fn test_audio_setup(
    state: tauri::State<'_, AppState>,
    mode: String,
) -> Result<AudioSetupCheck, String> {
    let tester = state.audio_setup.clone();
    tauri::async_runtime::spawn_blocking(move || tester.test(&mode))
        .await
        .map_err(|error| format!("audio check stopped unexpectedly: {error}"))?
}

#[tauri::command]
fn relaunch_app(app: tauri::AppHandle) {
    app.request_restart();
}

#[tauri::command]
async fn transcription_model_status(
    state: tauri::State<'_, AppState>,
) -> Result<Vec<TranscriptionModelStatus>, String> {
    let runtime = state.transcription.clone();
    tauri::async_runtime::spawn_blocking(move || runtime.statuses())
        .await
        .map_err(|error| format!("could not inspect local transcription models: {error}"))?
}

#[tauri::command]
async fn prepare_transcription_model(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    model: String,
) -> Result<Vec<TranscriptionModelStatus>, String> {
    let runtime = state.transcription.clone();
    tauri::async_runtime::spawn_blocking(move || {
        runtime.prepare_with_progress(&model, |status| {
            let _ = app.emit("arco:transcription-model-progress", status);
        })
    })
    .await
    .map_err(|error| format!("could not prepare local transcription model: {error}"))?
}

#[tauri::command]
async fn remove_transcription_model(
    state: tauri::State<'_, AppState>,
    model: String,
) -> Result<Vec<TranscriptionModelStatus>, String> {
    let runtime = state.transcription.clone();
    tauri::async_runtime::spawn_blocking(move || runtime.remove(&model))
        .await
        .map_err(|error| format!("could not remove local transcription model: {error}"))?
}

#[tauri::command(async)]
fn start_capture(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    mode: String,
    transcription: Option<TranscriptionConfig>,
    meeting_id: Option<String>,
) -> Result<CaptureState, String> {
    let _storage_guard = state
        .storage_change_lock
        .lock()
        .map_err(|_| "transcript storage coordinator is unavailable".to_string())?;
    let transcription = transcription.unwrap_or_default();
    state.transcription.validate_selection(&transcription)?;
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
        let active = state.capture.active_transcript_path();
        let detail = state.meetings.read(&meeting_id, active.as_deref())?;
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
        state.capture.resume_with_transcription_and_secrets(
            &mode,
            transcription,
            secrets,
            resume,
        )?
    } else {
        state
            .capture
            .start_with_transcription_and_secrets(&mode, transcription, secrets)?
    };
    if let Err(window_error) = overlay::show_hud(&app) {
        let rollback = state.capture.stop();
        if let Err(error) = overlay::release_capture_surfaces(&app) {
            log::warn!("Arco could not release a partially opened recording HUD: {error}");
        }
        return Err(match rollback {
            Ok(_) => format!("recording HUD could not open; capture was stopped: {window_error}"),
            Err(stop_error) => format!(
                "recording HUD could not open ({window_error}) and capture rollback failed ({stop_error})"
            ),
        });
    }
    if let Some(meeting_id) = resumed_meeting_id.as_deref() {
        if let Err(error) = state.meeting_state.invalidate_generated_summary(meeting_id) {
            log::warn!(
                "Arco continued meeting {meeting_id} but could not invalidate its old summary: {error}"
            );
        }
    }
    let _ = app.emit("arco:capture-changed", &capture);
    Ok(capture)
}

#[tauri::command(async)]
fn stop_capture(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
) -> Result<CaptureState, String> {
    let result = state.capture.stop();
    if let Err(error) = overlay::release_capture_surfaces(&app) {
        log::warn!("Arco stopped capture but could not release its capture surfaces: {error}");
    }
    let _ = app.emit("arco:capture-changed", state.capture.status());
    result
}

#[tauri::command(async)]
fn toggle_agent_overlay(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
) -> Result<bool, String> {
    let capture = state.capture.status();
    if capture.phase != "recording" || capture.active_meeting_id.is_none() {
        return Err("Start listening before opening Ask Arco".to_string());
    }
    let visible = overlay::toggle_agent(&app)?;
    if visible {
        let _ = app.emit("arco:agent-target-changed", capture.active_meeting_id);
    }
    Ok(visible)
}

#[tauri::command(async)]
fn hide_agent_overlay(app: tauri::AppHandle) -> Result<(), String> {
    overlay::hide_agent(&app)
}

#[tauri::command(async)]
fn set_agent_transcript_visible(app: tauri::AppHandle, visible: bool) -> Result<(), String> {
    overlay::set_agent_transcript_visible(&app, visible)
}

#[tauri::command(async)]
fn focus_main_window(app: tauri::AppHandle) -> Result<(), String> {
    overlay::focus_main(&app)
}

#[tauri::command(async)]
// Tauri deserializes command arguments by name, so this boundary intentionally
// mirrors the stable frontend invoke contract instead of hiding it in a blob.
#[allow(clippy::too_many_arguments)]
fn run_agent(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    provider: String,
    used_fallback: Option<bool>,
    question: String,
    agent_prompt: Option<String>,
    meeting_id: String,
    context_scope: Option<String>,
    workspace: Option<String>,
    request_id: String,
    on_event: Channel<AgentStreamEvent>,
) -> Result<PersistedAgentTurn, String> {
    let question = question.trim().to_string();
    if question.is_empty() {
        return Err("question cannot be empty".to_string());
    }
    let request_id = request_id.trim().to_string();
    if request_id.is_empty() || request_id.len() > 128 || request_id.chars().any(char::is_control) {
        return Err("invalid Agent request ID".to_string());
    }
    let agent_prompt = agent_prompt
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(question.as_str());
    // Keep preflight, provider execution, and atomic sidecar commit in one
    // critical section. This conservatively serializes all provider sessions
    // and prevents two first turns from creating competing native bindings.
    let _run_guard = state
        .agent_run_lock
        .lock()
        .map_err(|_| "agent session coordinator is unavailable".to_string())?;
    let active = state.capture.active_transcript_path();
    let meeting = state.meetings.read(&meeting_id, active.as_deref())?;
    let workspace = workspace
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .map(PathBuf::from);
    let context_scope = context_scope.as_deref().unwrap_or("transcript");
    let canonical_cwd = state
        .agent
        .working_directory(context_scope, workspace.as_deref())?;
    // Preflight the sidecar before spawning a provider. This prevents a
    // damaged local index from consuming a native turn that Arco cannot bind.
    let binding = state.meeting_state.session_binding(
        &meeting_id,
        &provider,
        context_scope,
        &canonical_cwd,
    )?;
    let expected_session_id = binding.as_ref().map(|binding| binding.session_id.as_str());
    let _ = on_event.send(AgentStreamEvent {
        event_type: "status".into(),
        request_id: request_id.clone(),
        meeting_id: meeting_id.clone(),
        phase: Some("starting".into()),
        answer: None,
    });
    let stream_channel = on_event.clone();
    let stream_request_id = request_id.clone();
    let stream_meeting_id = meeting_id.clone();
    let output = state.agent.run_session_streamed(
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
                },
                AgentStreamUpdate::Answer(answer) => AgentStreamEvent {
                    event_type: "answer".into(),
                    request_id: stream_request_id.clone(),
                    meeting_id: stream_meeting_id.clone(),
                    phase: None,
                    answer: Some(answer),
                },
            };
            let _ = stream_channel.send(event);
        },
    )?;
    let turn = state.meeting_state.commit_agent_turn(
        &meeting_id,
        &question,
        context_scope,
        &canonical_cwd,
        &output,
        used_fallback.unwrap_or(false),
        expected_session_id,
    )?;
    let _ = app.emit("arco:agent-thread-changed", &meeting_id);
    Ok(turn)
}

#[tauri::command(async)]
fn generate_meeting_output(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    provider: String,
    meeting_id: String,
    kind: String,
    prompt: String,
) -> Result<GeneratedMeetingArtifact, String> {
    let active = state.capture.active_transcript_path();
    let artifact = generate_meeting_output_once(
        &state.output_run_lock,
        &state.agent,
        &state.meetings,
        &state.meeting_state,
        &provider,
        &meeting_id,
        &kind,
        &prompt,
        active.as_deref(),
    )?;
    let _ = app.emit("arco:meeting-output-changed", &meeting_id);
    Ok(artifact)
}

#[tauri::command]
fn sync_native_search_field(
    window: tauri::WebviewWindow,
    state: NativeSearchFieldState,
) -> Result<bool, String> {
    native_search::sync_native_search_field(&window, state)
}

#[tauri::command]
fn sync_native_action_button(
    window: tauri::WebviewWindow,
    state: NativeActionButtonState,
) -> Result<bool, String> {
    native_action::sync_native_action_button(&window, state)
}

#[tauri::command]
fn sync_native_glass_surface(
    window: tauri::WebviewWindow,
    state: NativeGlassSurfaceState,
) -> Result<bool, String> {
    native_surface::sync_native_glass_surface(&window, state)
}

#[tauri::command]
fn sync_native_notes_toolbar(
    window: tauri::WebviewWindow,
    state: NativeNotesToolbarState,
) -> Result<bool, String> {
    native_notes_toolbar::sync_native_notes_toolbar(&window, state)
}

#[tauri::command]
fn sync_native_shell(
    window: tauri::WebviewWindow,
    state: NativeShellState,
) -> Result<bool, String> {
    native_shell::sync_native_shell(&window, state)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            if let Err(error) = listening_shortcut::register_default(app.handle()) {
                log::warn!("Arco could not register its default listening shortcut: {error}");
            }
            if cfg!(debug_assertions) {
                app.handle().plugin(
                    tauri_plugin_log::Builder::default()
                        .level(log::LevelFilter::Info)
                        .build(),
                )?;
            }
            #[cfg(target_os = "macos")]
            if let Err(error) = dock_icon::apply() {
                log::warn!("Arco could not install its transparent Dock icon: {error}");
            }
            #[cfg(target_os = "macos")]
            if let Some(window) = app.get_webview_window("main") {
                if let Err(error) = dock_icon::apply_to_window(&window) {
                    log::warn!(
                        "Arco could not install its transparent minimized-window icon: {error}"
                    );
                }
            } else {
                log::warn!("Arco could not find its main window; native shell was not prepared");
            }
            let resource_dir = app.path().resource_dir().ok();
            let paths = AppPaths::discover(resource_dir.as_deref())
                .map_err(|error| std::io::Error::other(format!("Arco setup failed: {error}")))?;
            app.manage(AppState::new(paths).map_err(std::io::Error::other)?);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_meetings,
            storage_settings,
            set_transcript_directory,
            notes_storage_settings,
            set_notes_directory,
            list_notes,
            save_note,
            delete_note,
            read_meeting,
            rename_meeting,
            list_agent_turns,
            list_saved_notes,
            set_agent_turn_saved,
            runtime_status,
            test_agent_provider,
            deepgram_credential_status,
            save_deepgram_api_key,
            remove_deepgram_api_key,
            open_deepgram_console,
            elevenlabs_credential_status,
            save_elevenlabs_api_key,
            remove_elevenlabs_api_key,
            open_elevenlabs_console,
            doubao_credential_status,
            save_doubao_credentials,
            remove_doubao_credentials,
            open_doubao_console,
            capture_status,
            test_audio_setup,
            relaunch_app,
            transcription_model_status,
            prepare_transcription_model,
            remove_transcription_model,
            start_capture,
            stop_capture,
            toggle_agent_overlay,
            hide_agent_overlay,
            set_agent_transcript_visible,
            focus_main_window,
            sync_native_search_field,
            sync_native_action_button,
            sync_native_glass_surface,
            sync_native_notes_toolbar,
            sync_native_shell,
            run_agent,
            generate_meeting_output
        ])
        .build(tauri::generate_context!())
        .expect("error while building Arco");
    app.run(|app_handle, event| {
        if matches!(
            event,
            tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit
        ) {
            if let Some(state) = app_handle.try_state::<AppState>() {
                state.capture.shutdown();
            }
        }
    });
}
