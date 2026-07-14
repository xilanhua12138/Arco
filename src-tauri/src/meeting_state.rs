use crate::models::{
    AgentReply, AgentRunOutput, AgentSessionBinding, GeneratedMeetingArtifact, MeetingArtifacts,
    MeetingSummary, PersistedAgentTurn, SavedNote,
};
use crate::storage::is_storage_source;
use chrono::Local;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tempfile::NamedTempFile;

const SCHEMA_VERSION: u32 = 4;
const PREVIOUS_SCHEMA_VERSION: u32 = 3;
const SECOND_PREVIOUS_SCHEMA_VERSION: u32 = 2;
const LEGACY_SCHEMA_VERSION: u32 = 1;
const MAX_MEETING_ID_BYTES: usize = 120;
const MAX_STATE_BYTES: u64 = 8 * 1024 * 1024;
const MAX_MANUAL_TITLE_CHARS: usize = 80;
static NEXT_TURN_ID: AtomicU64 = AtomicU64::new(0);

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MeetingStateFile {
    schema_version: u32,
    meeting_id: String,
    #[serde(default)]
    sessions: Vec<AgentSessionBinding>,
    #[serde(default)]
    artifacts: MeetingArtifacts,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    manual_title: Option<ManualMeetingTitle>,
    turns: Vec<PersistedAgentTurn>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManualMeetingTitle {
    value: Option<String>,
    updated_at: String,
}

impl MeetingStateFile {
    fn empty(meeting_id: &str) -> Self {
        Self {
            schema_version: SCHEMA_VERSION,
            meeting_id: meeting_id.to_string(),
            sessions: Vec::new(),
            artifacts: MeetingArtifacts::default(),
            manual_title: None,
            turns: Vec::new(),
        }
    }
}

#[derive(Debug)]
pub struct MeetingStateStore {
    root: PathBuf,
    lock: Mutex<()>,
}

impl MeetingStateStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            lock: Mutex::new(()),
        }
    }

    pub fn list(&self, meeting_id: &str) -> Result<Vec<PersistedAgentTurn>, String> {
        let path = self.sidecar_path(meeting_id)?;
        let _guard = self.acquire_lock()?;
        Ok(self.read_state(meeting_id, &path)?.turns)
    }

    pub fn list_saved_notes(
        &self,
        meetings: &[MeetingSummary],
        query: Option<&str>,
    ) -> Result<Vec<SavedNote>, String> {
        let normalized_query = query
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_lowercase);
        let _guard = self.acquire_lock()?;
        let mut notes = Vec::new();

        for meeting in meetings {
            let path = self.sidecar_path(&meeting.id)?;
            let state = self.read_state(&meeting.id, &path)?;
            for turn in state.turns.into_iter().filter(|turn| turn.saved_as_note) {
                if let Some(query) = normalized_query.as_deref() {
                    let searchable = format!(
                        "{}\n{}\n{}",
                        meeting.title.as_deref().unwrap_or_default(),
                        turn.question,
                        turn.answer,
                    )
                    .to_lowercase();
                    if !searchable.contains(query) {
                        continue;
                    }
                }
                notes.push(SavedNote {
                    meeting: meeting.clone(),
                    turn,
                });
            }
        }

        notes.sort_by(|left, right| {
            let left_time = chrono::DateTime::parse_from_rfc3339(&left.turn.created_at)
                .map(|value| value.timestamp_millis())
                .unwrap_or(i64::MIN);
            let right_time = chrono::DateTime::parse_from_rfc3339(&right.turn.created_at)
                .map(|value| value.timestamp_millis())
                .unwrap_or(i64::MIN);
            right_time
                .cmp(&left_time)
                .then_with(|| right.meeting.started_at.cmp(&left.meeting.started_at))
                .then_with(|| right.turn.id.cmp(&left.turn.id))
        });
        Ok(notes)
    }

    pub fn meeting_artifacts(&self, meeting_id: &str) -> Result<MeetingArtifacts, String> {
        let path = self.sidecar_path(meeting_id)?;
        let _guard = self.acquire_lock()?;
        Ok(self.read_state(meeting_id, &path)?.artifacts)
    }

    pub fn invalidate_generated_summary(&self, meeting_id: &str) -> Result<(), String> {
        let path = self.sidecar_path(meeting_id)?;
        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        if state.artifacts.summary.take().is_some() {
            self.write_state(&path, &state)?;
        }
        Ok(())
    }

    pub fn hydrate_meeting_summary(&self, summary: &mut MeetingSummary) -> Result<(), String> {
        let path = self.sidecar_path(&summary.id)?;
        let _guard = self.acquire_lock()?;
        let state = self.read_state(&summary.id, &path)?;
        summary.title_generation_status = artifact_status(state.artifacts.title.as_ref()).into();
        summary.summary_generation_status =
            artifact_status(state.artifacts.summary.as_ref()).into();
        if let Some(manual_title) = state.manual_title {
            summary.title = manual_title.value;
            // A deliberate title, including a deliberate untitled state, closes
            // the automatic-title workflow and must never be replaced by it.
            summary.title_generation_status = "ready".into();
        } else if let Some(value) = ready_artifact_value(state.artifacts.title.as_ref()) {
            summary.title = Some(value.to_string());
        }
        summary.generated_summary =
            ready_artifact_value(state.artifacts.summary.as_ref()).map(str::to_string);
        Ok(())
    }

    pub fn set_manual_title(&self, meeting_id: &str, title: Option<&str>) -> Result<(), String> {
        let path = self.sidecar_path(meeting_id)?;
        let normalized = title.map(str::trim).filter(|value| !value.is_empty());
        if let Some(value) = normalized {
            if value.chars().count() > MAX_MANUAL_TITLE_CHARS {
                return Err(format!(
                    "meeting title is too long (maximum {MAX_MANUAL_TITLE_CHARS} characters)"
                ));
            }
            if value.chars().any(char::is_control) {
                return Err("meeting title must be a single line".into());
            }
        }

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        state.manual_title = Some(ManualMeetingTitle {
            value: normalized.map(str::to_string),
            updated_at: Local::now().to_rfc3339(),
        });
        self.write_state(&path, &state)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn commit_meeting_artifact(
        &self,
        meeting_id: &str,
        kind: &str,
        context_scope: &str,
        canonical_cwd: &Path,
        output: &AgentRunOutput,
        value: &str,
        expected_session_id: Option<&str>,
    ) -> Result<GeneratedMeetingArtifact, String> {
        let path = self.sidecar_path(meeting_id)?;
        validate_artifact_kind(kind)?;
        validate_context_scope(context_scope)?;
        if context_scope != "meeting-output" {
            return Err("generated meeting artifacts require meeting-output context".into());
        }
        validate_provider(&output.reply.provider)?;
        validate_native_session_id(&output.provider_session_id)?;
        validate_provider_turn_id(output.provider_turn_id.as_deref())?;
        let value = value.trim();
        if value.is_empty() {
            return Err(format!("generated meeting {kind} cannot be empty"));
        }
        if let Some(expected) = expected_session_id {
            validate_native_session_id(expected)?;
            if expected != output.provider_session_id {
                return Err(format!(
                    "{} returned a different native session ID: expected {expected}, got {}",
                    output.reply.provider, output.provider_session_id
                ));
            }
        }
        let canonical_cwd = validate_canonical_cwd(canonical_cwd)?;

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        if let Some(existing) = artifact_for_kind(&state.artifacts, kind) {
            return Ok(existing.clone());
        }
        let now = Local::now().to_rfc3339();
        upsert_session_binding(
            &mut state,
            context_scope,
            &canonical_cwd,
            output,
            expected_session_id,
            &now,
        )?;
        let artifact = GeneratedMeetingArtifact {
            kind: kind.to_string(),
            status: "ready".into(),
            value: Some(value.to_string()),
            provider: Some(output.reply.provider.clone()),
            provider_session_id: Some(output.provider_session_id.clone()),
            provider_turn_id: output.provider_turn_id.clone(),
            error: None,
            updated_at: now,
        };
        *artifact_for_kind_mut(&mut state.artifacts, kind)? = Some(artifact.clone());
        self.write_state(&path, &state)?;
        Ok(artifact)
    }

    pub fn commit_failed_meeting_artifact(
        &self,
        meeting_id: &str,
        kind: &str,
        provider: &str,
        error: &str,
    ) -> Result<GeneratedMeetingArtifact, String> {
        let path = self.sidecar_path(meeting_id)?;
        validate_artifact_kind(kind)?;
        validate_provider(provider)?;
        let error = error.trim();
        if error.is_empty() {
            return Err("generated meeting artifact failure must include an error".into());
        }

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        if let Some(existing) = artifact_for_kind(&state.artifacts, kind) {
            return Ok(existing.clone());
        }
        let artifact = GeneratedMeetingArtifact {
            kind: kind.to_string(),
            status: "failed".into(),
            value: None,
            provider: Some(provider.to_string()),
            provider_session_id: None,
            provider_turn_id: None,
            error: Some(error.to_string()),
            updated_at: Local::now().to_rfc3339(),
        };
        *artifact_for_kind_mut(&mut state.artifacts, kind)? = Some(artifact.clone());
        self.write_state(&path, &state)?;
        Ok(artifact)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn commit_failed_meeting_artifact_with_output(
        &self,
        meeting_id: &str,
        kind: &str,
        context_scope: &str,
        canonical_cwd: &Path,
        output: &AgentRunOutput,
        error: &str,
        expected_session_id: Option<&str>,
    ) -> Result<GeneratedMeetingArtifact, String> {
        let path = self.sidecar_path(meeting_id)?;
        validate_artifact_kind(kind)?;
        validate_context_scope(context_scope)?;
        if context_scope != "meeting-output" {
            return Err("generated meeting artifacts require meeting-output context".into());
        }
        validate_provider(&output.reply.provider)?;
        validate_native_session_id(&output.provider_session_id)?;
        validate_provider_turn_id(output.provider_turn_id.as_deref())?;
        if let Some(expected) = expected_session_id {
            validate_native_session_id(expected)?;
            if expected != output.provider_session_id {
                return Err(format!(
                    "{} returned a different native session ID: expected {expected}, got {}",
                    output.reply.provider, output.provider_session_id
                ));
            }
        }
        let error = error.trim();
        if error.is_empty() {
            return Err("generated meeting artifact failure must include an error".into());
        }
        let canonical_cwd = validate_canonical_cwd(canonical_cwd)?;

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        if let Some(existing) = artifact_for_kind(&state.artifacts, kind) {
            return Ok(existing.clone());
        }
        let now = Local::now().to_rfc3339();
        upsert_session_binding(
            &mut state,
            context_scope,
            &canonical_cwd,
            output,
            expected_session_id,
            &now,
        )?;
        let artifact = GeneratedMeetingArtifact {
            kind: kind.to_string(),
            status: "failed".into(),
            value: None,
            provider: Some(output.reply.provider.clone()),
            provider_session_id: Some(output.provider_session_id.clone()),
            provider_turn_id: output.provider_turn_id.clone(),
            error: Some(error.to_string()),
            updated_at: now,
        };
        *artifact_for_kind_mut(&mut state.artifacts, kind)? = Some(artifact.clone());
        self.write_state(&path, &state)?;
        Ok(artifact)
    }

    pub fn session_binding(
        &self,
        meeting_id: &str,
        provider: &str,
        context_scope: &str,
        canonical_cwd: &Path,
    ) -> Result<Option<AgentSessionBinding>, String> {
        let path = self.sidecar_path(meeting_id)?;
        validate_provider(provider)?;
        validate_context_scope(context_scope)?;
        let canonical_cwd = validate_canonical_cwd(canonical_cwd)?;
        let _guard = self.acquire_lock()?;
        let state = self.read_state(meeting_id, &path)?;
        Ok(state.sessions.into_iter().find(|binding| {
            binding.provider == provider
                && binding.context_scope == context_scope
                && binding.canonical_cwd == canonical_cwd
        }))
    }

    // These fields form the atomic persistence contract for one native agent turn.
    // Keeping them explicit makes it harder to accidentally commit a turn under
    // a different meeting, scope, workspace, or provider session.
    #[allow(clippy::too_many_arguments)]
    pub fn commit_agent_turn(
        &self,
        meeting_id: &str,
        question: &str,
        context_scope: &str,
        canonical_cwd: &Path,
        output: &AgentRunOutput,
        used_fallback: bool,
        expected_session_id: Option<&str>,
    ) -> Result<PersistedAgentTurn, String> {
        let path = self.sidecar_path(meeting_id)?;
        let question = question.trim();
        if question.is_empty() {
            return Err("question cannot be empty".into());
        }
        validate_context_scope(context_scope)?;
        validate_provider(&output.reply.provider)?;
        validate_native_session_id(&output.provider_session_id)?;
        if let Some(expected) = expected_session_id {
            validate_native_session_id(expected)?;
            if expected != output.provider_session_id {
                return Err(format!(
                    "{} returned a different native session ID: expected {expected}, got {}",
                    output.reply.provider, output.provider_session_id
                ));
            }
        }
        validate_provider_turn_id(output.provider_turn_id.as_deref())?;
        let canonical_cwd = validate_canonical_cwd(canonical_cwd)?;

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        let now = Local::now().to_rfc3339();
        match state.sessions.iter_mut().find(|binding| {
            binding.provider == output.reply.provider
                && binding.context_scope == context_scope
                && binding.canonical_cwd == canonical_cwd
        }) {
            Some(binding) => {
                if binding.session_id != output.provider_session_id {
                    return Err(format!(
                        "native session binding changed for {} {context_scope}: expected {}, got {}",
                        output.reply.provider, binding.session_id, output.provider_session_id
                    ));
                }
                binding.updated_at = now;
            }
            None => {
                if let Some(expected) = expected_session_id {
                    return Err(format!(
                        "native session binding disappeared before commit: {expected}"
                    ));
                }
                state.sessions.push(AgentSessionBinding {
                    provider: output.reply.provider.clone(),
                    session_id: output.provider_session_id.clone(),
                    context_scope: context_scope.to_string(),
                    canonical_cwd: canonical_cwd.clone(),
                    created_at: now.clone(),
                    updated_at: now,
                });
            }
        }

        let turn = new_persisted_turn(
            meeting_id,
            question,
            context_scope,
            &output.reply,
            used_fallback,
            Some(output.provider_session_id.clone()),
            output.provider_turn_id.clone(),
        );
        state.turns.push(turn.clone());
        self.write_state(&path, &state)?;
        Ok(turn)
    }

    pub fn append_agent_turn(
        &self,
        meeting_id: &str,
        question: &str,
        context_scope: &str,
        reply: &AgentReply,
    ) -> Result<PersistedAgentTurn, String> {
        let path = self.sidecar_path(meeting_id)?;
        let question = question.trim();
        if question.is_empty() {
            return Err("question cannot be empty".into());
        }
        validate_context_scope(context_scope)?;
        validate_provider(&reply.provider)?;

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        let turn = new_persisted_turn(
            meeting_id,
            question,
            context_scope,
            reply,
            false,
            None,
            None,
        );
        state.turns.push(turn.clone());
        self.write_state(&path, &state)?;
        Ok(turn)
    }

    pub fn set_saved(
        &self,
        meeting_id: &str,
        turn_id: &str,
        saved: bool,
    ) -> Result<PersistedAgentTurn, String> {
        let path = self.sidecar_path(meeting_id)?;
        if turn_id.is_empty() || turn_id.len() > 160 || turn_id.chars().any(char::is_control) {
            return Err("invalid agent turn id".into());
        }

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        let turn = state
            .turns
            .iter_mut()
            .find(|turn| turn.id == turn_id)
            .ok_or_else(|| format!("agent turn not found for meeting {meeting_id}: {turn_id}"))?;
        if turn.saved_as_note == saved {
            return Ok(turn.clone());
        }
        turn.saved_as_note = saved;
        if !saved {
            turn.note_id = None;
        }
        let updated = turn.clone();
        self.write_state(&path, &state)?;
        Ok(updated)
    }

    pub fn link_saved_note(
        &self,
        meeting_id: &str,
        turn_id: &str,
        note_id: Option<&str>,
    ) -> Result<PersistedAgentTurn, String> {
        let path = self.sidecar_path(meeting_id)?;
        if turn_id.is_empty() || turn_id.len() > 160 || turn_id.chars().any(char::is_control) {
            return Err("invalid agent turn id".into());
        }
        if note_id.is_some_and(|value| {
            value.is_empty()
                || value.len() > 320
                || !value.ends_with(".md")
                || value.chars().any(char::is_control)
        }) {
            return Err("invalid note id".into());
        }

        let _guard = self.acquire_lock()?;
        let mut state = self.read_state(meeting_id, &path)?;
        let turn = state
            .turns
            .iter_mut()
            .find(|turn| turn.id == turn_id)
            .ok_or_else(|| format!("agent turn not found for meeting {meeting_id}: {turn_id}"))?;
        turn.saved_as_note = note_id.is_some();
        turn.note_id = note_id.map(str::to_string);
        let updated = turn.clone();
        self.write_state(&path, &state)?;
        Ok(updated)
    }

    fn acquire_lock(&self) -> Result<std::sync::MutexGuard<'_, ()>, String> {
        self.lock
            .lock()
            .map_err(|_| "meeting state storage lock is unavailable".to_string())
    }

    fn sidecar_path(&self, meeting_id: &str) -> Result<PathBuf, String> {
        validate_meeting_id(meeting_id)?;
        Ok(self
            .root
            .join(format!("{}.json", encode_hex(meeting_id.as_bytes()))))
    }

    fn read_state(&self, meeting_id: &str, path: &Path) -> Result<MeetingStateFile, String> {
        if !path.exists() {
            return Ok(MeetingStateFile::empty(meeting_id));
        }
        let metadata = fs::metadata(path).map_err(|error| {
            damaged_state_error(meeting_id, path, &format!("could not inspect it: {error}"))
        })?;
        if metadata.len() > MAX_STATE_BYTES {
            return Err(damaged_state_error(
                meeting_id,
                path,
                &format!(
                    "it is too large ({} bytes, maximum {MAX_STATE_BYTES})",
                    metadata.len()
                ),
            ));
        }
        let bytes = fs::read(path).map_err(|error| {
            damaged_state_error(meeting_id, path, &format!("could not read it: {error}"))
        })?;
        let mut state: MeetingStateFile = serde_json::from_slice(&bytes).map_err(|error| {
            damaged_state_error(meeting_id, path, &format!("invalid JSON: {error}"))
        })?;
        match state.schema_version {
            LEGACY_SCHEMA_VERSION => {
                if !state.sessions.is_empty() {
                    return Err(damaged_state_error(
                        meeting_id,
                        path,
                        "a v1 file unexpectedly contains native sessions",
                    ));
                }
                state.schema_version = SCHEMA_VERSION;
            }
            SECOND_PREVIOUS_SCHEMA_VERSION | PREVIOUS_SCHEMA_VERSION => {
                state.schema_version = SCHEMA_VERSION;
            }
            SCHEMA_VERSION => {}
            other => {
                return Err(damaged_state_error(
                    meeting_id,
                    path,
                    &format!("unsupported schema version {other}"),
                ));
            }
        }
        validate_state(meeting_id, path, &state)?;
        Ok(state)
    }

    fn write_state(&self, path: &Path, state: &MeetingStateFile) -> Result<(), String> {
        fs::create_dir_all(&self.root).map_err(|error| {
            format!(
                "could not create meeting state directory {}: {error}",
                self.root.display()
            )
        })?;
        let bytes = serde_json::to_vec_pretty(state)
            .map_err(|error| format!("could not serialize meeting state: {error}"))?;
        if bytes.len() as u64 > MAX_STATE_BYTES {
            return Err(format!(
                "meeting state is too large to save ({} bytes, maximum {MAX_STATE_BYTES})",
                bytes.len()
            ));
        }

        let mut temporary = NamedTempFile::new_in(&self.root).map_err(|error| {
            format!(
                "could not create an atomic meeting state file in {}: {error}",
                self.root.display()
            )
        })?;
        temporary
            .write_all(&bytes)
            .and_then(|_| temporary.flush())
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|error| format!("could not write meeting state atomically: {error}"))?;
        temporary.persist(path).map_err(|error| {
            format!(
                "could not replace meeting state {} atomically: {}",
                path.display(),
                error.error
            )
        })?;
        fs::File::open(&self.root)
            .and_then(|directory| directory.sync_all())
            .map_err(|error| format!("meeting state was saved but not synced to disk: {error}"))?;
        Ok(())
    }
}

fn artifact_for_kind<'a>(
    artifacts: &'a MeetingArtifacts,
    kind: &str,
) -> Option<&'a GeneratedMeetingArtifact> {
    match kind {
        "title" => artifacts.title.as_ref(),
        "summary" => artifacts.summary.as_ref(),
        _ => None,
    }
}

fn artifact_for_kind_mut<'a>(
    artifacts: &'a mut MeetingArtifacts,
    kind: &str,
) -> Result<&'a mut Option<GeneratedMeetingArtifact>, String> {
    match kind {
        "title" => Ok(&mut artifacts.title),
        "summary" => Ok(&mut artifacts.summary),
        _ => Err(format!(
            "unsupported meeting output kind: {kind}; expected title or summary"
        )),
    }
}

fn artifact_status(artifact: Option<&GeneratedMeetingArtifact>) -> &'static str {
    match artifact.map(|artifact| artifact.status.as_str()) {
        Some("ready") => "ready",
        Some("failed") => "failed",
        _ => "idle",
    }
}

fn ready_artifact_value(artifact: Option<&GeneratedMeetingArtifact>) -> Option<&str> {
    artifact
        .filter(|artifact| artifact.status == "ready")
        .and_then(|artifact| artifact.value.as_deref())
}

fn upsert_session_binding(
    state: &mut MeetingStateFile,
    context_scope: &str,
    canonical_cwd: &str,
    output: &AgentRunOutput,
    expected_session_id: Option<&str>,
    now: &str,
) -> Result<(), String> {
    match state.sessions.iter_mut().find(|binding| {
        binding.provider == output.reply.provider
            && binding.context_scope == context_scope
            && binding.canonical_cwd == canonical_cwd
    }) {
        Some(binding) => {
            if binding.session_id != output.provider_session_id {
                return Err(format!(
                    "native session binding changed for {} {context_scope}: expected {}, got {}",
                    output.reply.provider, binding.session_id, output.provider_session_id
                ));
            }
            binding.updated_at = now.to_string();
        }
        None => {
            if let Some(expected) = expected_session_id {
                return Err(format!(
                    "native session binding disappeared before commit: {expected}"
                ));
            }
            state.sessions.push(AgentSessionBinding {
                provider: output.reply.provider.clone(),
                session_id: output.provider_session_id.clone(),
                context_scope: context_scope.to_string(),
                canonical_cwd: canonical_cwd.to_string(),
                created_at: now.to_string(),
                updated_at: now.to_string(),
            });
        }
    }
    Ok(())
}

fn validate_artifact_kind(kind: &str) -> Result<(), String> {
    if matches!(kind, "title" | "summary") {
        Ok(())
    } else {
        Err(format!(
            "unsupported meeting output kind: {kind}; expected title or summary"
        ))
    }
}

fn validate_generated_artifact(
    kind: &str,
    artifact: &GeneratedMeetingArtifact,
    sessions: &[AgentSessionBinding],
) -> Result<(), String> {
    if artifact.kind != kind || artifact.updated_at.trim().is_empty() {
        return Err("invalid generated meeting artifact identity".into());
    }
    if let Some(provider) = artifact.provider.as_deref() {
        validate_provider(provider)?;
    }
    validate_provider_turn_id(artifact.provider_turn_id.as_deref())?;
    match artifact.status.as_str() {
        "ready" => {
            let value = artifact
                .value
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .ok_or_else(|| "ready artifact has no value".to_string())?;
            let _ = value;
            let provider = artifact
                .provider
                .as_deref()
                .ok_or_else(|| "ready artifact has no provider".to_string())?;
            let session_id = artifact
                .provider_session_id
                .as_deref()
                .ok_or_else(|| "ready artifact has no provider session".to_string())?;
            validate_native_session_id(session_id)?;
            if artifact.error.is_some()
                || !sessions.iter().any(|binding| {
                    binding.provider == provider
                        && binding.session_id == session_id
                        && binding.context_scope == "meeting-output"
                })
            {
                return Err("ready artifact is not bound to its meeting-output session".into());
            }
        }
        "failed" => {
            if artifact.value.is_some()
                || artifact.provider.is_none()
                || artifact
                    .error
                    .as_deref()
                    .map(str::trim)
                    .filter(|error| !error.is_empty())
                    .is_none()
            {
                return Err("failed artifact has inconsistent fields".into());
            }
            match artifact.provider_session_id.as_deref() {
                Some(session_id) => {
                    validate_native_session_id(session_id)?;
                    let provider = artifact
                        .provider
                        .as_deref()
                        .expect("failed artifact provider was checked above");
                    if !sessions.iter().any(|binding| {
                        binding.provider == provider
                            && binding.session_id == session_id
                            && binding.context_scope == "meeting-output"
                    }) {
                        return Err(
                            "failed artifact is not bound to its trusted meeting-output session"
                                .into(),
                        );
                    }
                }
                None if artifact.provider_turn_id.is_some() => {
                    return Err("failed artifact turn has no provider session".into())
                }
                None => {}
            }
        }
        _ => return Err("invalid generated meeting artifact status".into()),
    }
    Ok(())
}

fn validate_meeting_id(meeting_id: &str) -> Result<(), String> {
    if meeting_id.is_empty() || meeting_id.len() > MAX_MEETING_ID_BYTES {
        return Err("invalid meeting id".into());
    }
    let (source, file_name) = meeting_id
        .split_once(':')
        .ok_or_else(|| "invalid meeting id".to_string())?;
    if !(source == "legacy" || is_storage_source(source))
        || file_name.is_empty()
        || file_name.contains(['/', '\\', ':'])
        || file_name.chars().any(char::is_control)
        || !(file_name.starts_with("meeting-") || file_name.starts_with("transcript-"))
        || !file_name.ends_with(".md")
    {
        return Err("invalid meeting id".into());
    }
    Ok(())
}

fn validate_state(meeting_id: &str, path: &Path, state: &MeetingStateFile) -> Result<(), String> {
    if state.schema_version != SCHEMA_VERSION {
        return Err(damaged_state_error(
            meeting_id,
            path,
            &format!("unsupported schema version {}", state.schema_version),
        ));
    }
    if state.meeting_id != meeting_id {
        return Err(damaged_state_error(
            meeting_id,
            path,
            "the embedded meeting ID does not match this meeting",
        ));
    }
    if let Some(manual_title) = state.manual_title.as_ref() {
        if manual_title.updated_at.trim().is_empty()
            || manual_title.value.as_deref().is_some_and(|value| {
                value.trim() != value
                    || value.is_empty()
                    || value.chars().count() > MAX_MANUAL_TITLE_CHARS
                    || value.chars().any(char::is_control)
            })
        {
            return Err(damaged_state_error(
                meeting_id,
                path,
                "it contains an invalid manual meeting title",
            ));
        }
    }
    let mut ids = HashSet::new();
    if state.turns.iter().any(|turn| {
        turn.meeting_id != meeting_id || turn.id.is_empty() || !ids.insert(turn.id.as_str())
    }) {
        return Err(damaged_state_error(
            meeting_id,
            path,
            "it contains a mismatched meeting ID or duplicate/empty turn ID",
        ));
    }
    let mut binding_keys = HashSet::new();
    let mut native_sessions = HashSet::new();
    if state.sessions.iter().any(|binding| {
        validate_provider(&binding.provider).is_err()
            || validate_context_scope(&binding.context_scope).is_err()
            || validate_native_session_id(&binding.session_id).is_err()
            || binding.canonical_cwd.is_empty()
            || !Path::new(&binding.canonical_cwd).is_absolute()
            || !binding_keys.insert((
                binding.provider.as_str(),
                binding.context_scope.as_str(),
                binding.canonical_cwd.as_str(),
            ))
            || !native_sessions.insert((binding.provider.as_str(), binding.session_id.as_str()))
    }) {
        return Err(damaged_state_error(
            meeting_id,
            path,
            "it contains an invalid or duplicate native session binding",
        ));
    }
    for (kind, artifact) in [
        ("title", state.artifacts.title.as_ref()),
        ("summary", state.artifacts.summary.as_ref()),
    ] {
        if let Some(artifact) = artifact {
            if validate_generated_artifact(kind, artifact, &state.sessions).is_err() {
                return Err(damaged_state_error(
                    meeting_id,
                    path,
                    "it contains an invalid generated meeting artifact",
                ));
            }
        }
    }
    if state.turns.iter().any(|turn| {
        turn.provider_session_id
            .as_deref()
            .map(validate_native_session_id)
            .transpose()
            .is_err()
            || validate_provider_turn_id(turn.provider_turn_id.as_deref()).is_err()
            || turn.note_id.as_deref().is_some_and(|note_id| {
                note_id.is_empty()
                    || note_id.len() > 320
                    || !note_id.ends_with(".md")
                    || note_id.chars().any(char::is_control)
            })
    }) {
        return Err(damaged_state_error(
            meeting_id,
            path,
            "it contains an invalid provider session or turn ID",
        ));
    }
    Ok(())
}

fn new_persisted_turn(
    meeting_id: &str,
    question: &str,
    context_scope: &str,
    reply: &AgentReply,
    used_fallback: bool,
    provider_session_id: Option<String>,
    provider_turn_id: Option<String>,
) -> PersistedAgentTurn {
    PersistedAgentTurn {
        id: new_turn_id(),
        meeting_id: meeting_id.to_string(),
        provider: reply.provider.clone(),
        question: question.to_string(),
        answer: reply.answer.clone(),
        sources: reply.sources.clone(),
        context_scope: context_scope.to_string(),
        created_at: reply.created_at.clone(),
        saved_as_note: false,
        note_id: None,
        used_fallback,
        provider_session_id,
        provider_turn_id,
    }
}

fn validate_canonical_cwd(path: &Path) -> Result<String, String> {
    if !path.is_absolute() {
        return Err(format!(
            "agent session working directory must be absolute: {}",
            path.display()
        ));
    }
    if !path.exists() || !path.is_dir() {
        return Err(format!(
            "agent session working directory is unavailable: {}",
            path.display()
        ));
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("could not resolve agent session working directory: {error}"))?;
    if canonical != path {
        return Err(format!(
            "agent session working directory must already be canonical: expected {}, got {}",
            canonical.display(),
            path.display()
        ));
    }
    canonical
        .into_os_string()
        .into_string()
        .map_err(|_| "agent session working directory must be valid UTF-8".to_string())
}

fn validate_native_session_id(session_id: &str) -> Result<(), String> {
    uuid::Uuid::parse_str(session_id)
        .map(|_| ())
        .map_err(|_| format!("invalid native provider session ID: {session_id}"))
}

fn validate_provider_turn_id(turn_id: Option<&str>) -> Result<(), String> {
    if let Some(turn_id) = turn_id {
        if turn_id.is_empty() || turn_id.len() > 256 || turn_id.chars().any(char::is_control) {
            return Err("invalid native provider turn ID".into());
        }
    }
    Ok(())
}

fn validate_context_scope(context_scope: &str) -> Result<(), String> {
    if matches!(
        context_scope,
        "transcript" | "meeting-output" | "workspace" | "personal"
    ) {
        Ok(())
    } else {
        Err(format!("unsupported context scope: {context_scope}"))
    }
}

fn validate_provider(provider: &str) -> Result<(), String> {
    if matches!(provider, "codex" | "claude") {
        Ok(())
    } else {
        Err(format!("unsupported agent provider: {provider}"))
    }
}

fn new_turn_id() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let sequence = NEXT_TURN_ID.fetch_add(1, Ordering::Relaxed);
    format!(
        "turn-{nanos:032x}-{:08x}-{sequence:016x}",
        std::process::id()
    )
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

fn damaged_state_error(meeting_id: &str, path: &Path, detail: &str) -> String {
    format!(
        "meeting state is damaged for {meeting_id}: {detail}. The transcript is unaffected; move or remove {} to rebuild this Agent thread",
        path.display()
    )
}
