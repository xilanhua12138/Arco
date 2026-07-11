pub mod agent;
pub mod capture;
#[cfg(target_os = "macos")]
mod dock_icon;
#[cfg(target_os = "macos")]
mod fn_shortcut;
mod material;
pub mod meeting_output;
pub mod meeting_state;
pub mod meetings;
pub mod models;
mod overlay;
pub mod paths;
pub mod process;
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

use agent::AgentRunner;
use capture::{CaptureConfig, CaptureManager};
use meeting_output::{
    generate_meeting_output_once, list_meetings_with_artifacts, read_meeting_with_artifacts,
};
use meeting_state::MeetingStateStore;
use meetings::MeetingStore;
use models::{
    CaptureState, GeneratedMeetingArtifact, MeetingDetail, MeetingSummary, PersistedAgentTurn,
    ProviderConnectionTest, RuntimeStatus, TranscriptionConfig, TranscriptionModelStatus,
};
use paths::AppPaths;
use std::path::PathBuf;
use std::sync::Mutex;
use storage::{TranscriptStorage, TranscriptStorageSettings};
use tauri::{Emitter, Manager};
use transcription::LocalTranscriptionRuntime;

pub struct AppState {
    meetings: MeetingStore,
    meeting_state: MeetingStateStore,
    capture: CaptureManager,
    transcription: LocalTranscriptionRuntime,
    agent: AgentRunner,
    agent_run_lock: Mutex<()>,
    output_run_lock: Mutex<()>,
    storage: TranscriptStorage,
    storage_change_lock: Mutex<()>,
}

impl AppState {
    pub fn new(paths: AppPaths) -> Result<Self, String> {
        let agent_workspace = paths.app_data.join("agent-workspace");
        let storage = TranscriptStorage::load(paths.app_data.clone(), paths.transcripts.clone())?;
        let meetings =
            MeetingStore::new(paths.transcripts.clone(), paths.legacy_transcripts.clone());
        meetings.set_roots(storage.meeting_roots())?;
        let capture = CaptureManager::new(CaptureConfig::discover(&paths));
        capture.set_transcript_root(storage.active_root())?;
        Ok(Self {
            meetings,
            meeting_state: MeetingStateStore::new(paths.app_data.join("meeting-state")),
            capture,
            transcription: LocalTranscriptionRuntime::discover(&paths),
            agent: AgentRunner::new(agent_workspace),
            agent_run_lock: Mutex::new(()),
            output_run_lock: Mutex::new(()),
            storage,
            storage_change_lock: Mutex::new(()),
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
fn set_agent_turn_saved(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    meeting_id: String,
    turn_id: String,
    saved: bool,
) -> Result<PersistedAgentTurn, String> {
    let active = state.capture.active_transcript_path();
    state.meetings.read(&meeting_id, active.as_deref())?;
    let turn = state
        .meeting_state
        .set_saved(&meeting_id, &turn_id, saved)?;
    let _ = app.emit("arco:agent-thread-changed", &meeting_id);
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
fn capture_status(state: tauri::State<'_, AppState>) -> CaptureState {
    state.capture.status()
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
    include_diarization: bool,
) -> Result<Vec<TranscriptionModelStatus>, String> {
    let runtime = state.transcription.clone();
    tauri::async_runtime::spawn_blocking(move || {
        runtime.prepare_with_progress(&model, include_diarization, |status| {
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
) -> Result<CaptureState, String> {
    let _storage_guard = state
        .storage_change_lock
        .lock()
        .map_err(|_| "transcript storage coordinator is unavailable".to_string())?;
    let capture = state
        .capture
        .start_with_transcription(&mode, transcription.unwrap_or_default())?;
    if let Err(window_error) = overlay::show_hud(&app) {
        let rollback = state.capture.stop();
        return Err(match rollback {
            Ok(_) => format!("recording HUD could not open; capture was stopped: {window_error}"),
            Err(stop_error) => format!(
                "recording HUD could not open ({window_error}) and capture rollback failed ({stop_error})"
            ),
        });
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
    if let Err(error) = overlay::hide_hud(&app) {
        log::warn!("Arco stopped capture but could not hide the recording HUD: {error}");
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
    let visible = overlay::show_or_focus_agent(&app)?;
    let _ = app.emit("arco:agent-target-changed", capture.active_meeting_id);
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
fn run_agent(
    app: tauri::AppHandle,
    state: tauri::State<'_, AppState>,
    provider: String,
    used_fallback: Option<bool>,
    question: String,
    meeting_id: String,
    context_scope: Option<String>,
    workspace: Option<String>,
) -> Result<PersistedAgentTurn, String> {
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
    let output = state.agent.run_session(
        &provider,
        &question,
        &meeting,
        context_scope,
        workspace.as_deref(),
        expected_session_id,
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            #[cfg(target_os = "macos")]
            fn_shortcut::start(app.handle().clone());
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
                material::apply_native_material(&window);
                if let Err(error) = dock_icon::apply_to_window(&window) {
                    log::warn!(
                        "Arco could not install its transparent minimized-window icon: {error}"
                    );
                }
            } else {
                log::warn!("Arco could not find its main window; native material was not applied");
            }
            let resource_dir = app.path().resource_dir().ok();
            let paths = AppPaths::discover(resource_dir.as_deref())
                .map_err(|error| std::io::Error::other(format!("Arco setup failed: {error}")))?;
            app.manage(AppState::new(paths).map_err(std::io::Error::other)?);
            overlay::create_overlay_windows(app)?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            list_meetings,
            storage_settings,
            set_transcript_directory,
            read_meeting,
            rename_meeting,
            list_agent_turns,
            set_agent_turn_saved,
            runtime_status,
            test_agent_provider,
            capture_status,
            transcription_model_status,
            prepare_transcription_model,
            remove_transcription_model,
            start_capture,
            stop_capture,
            toggle_agent_overlay,
            hide_agent_overlay,
            set_agent_transcript_visible,
            focus_main_window,
            run_agent,
            generate_meeting_output
        ])
        .run(tauri::generate_context!())
        .expect("error while running Arco");
}
