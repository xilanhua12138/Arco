use crate::meeting_state::MeetingStateStore;
use crate::models::{MeetingSummary, NoteDocument, PersistedAgentTurn};
use crate::storage::is_storage_source;
use chrono::{DateTime, Local};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use tempfile::NamedTempFile;
use uuid::Uuid;

const STORAGE_SCHEMA_VERSION: u32 = 1;
const STORAGE_FILE_NAME: &str = "notes-storage.json";
const NOTE_PREFIX: &str = "<!-- arco-note ";
const MAX_NOTE_BYTES: u64 = 4 * 1024 * 1024;
const MAX_TITLE_CHARS: usize = 120;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NoteRoot {
    pub source: String,
    pub path: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesStorageSettings {
    pub default_directory: PathBuf,
    pub selected_directory: PathBuf,
    pub using_default: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CustomRoot {
    source: String,
    path: PathBuf,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedStorage {
    schema_version: u32,
    active_source: String,
    #[serde(default)]
    custom_roots: Vec<CustomRoot>,
}

impl Default for PersistedStorage {
    fn default() -> Self {
        Self {
            schema_version: STORAGE_SCHEMA_VERSION,
            active_source: "local".into(),
            custom_roots: Vec::new(),
        }
    }
}

#[derive(Debug)]
pub struct NotesStorage {
    default_directory: PathBuf,
    config_path: PathBuf,
    state: Mutex<PersistedStorage>,
}

impl NotesStorage {
    pub fn load(app_data: PathBuf, default_directory: PathBuf) -> Result<Self, String> {
        if !default_directory.is_absolute() {
            return Err("default notes directory must be absolute".into());
        }
        fs::create_dir_all(&default_directory).map_err(|error| {
            format!(
                "could not create default notes directory {}: {error}",
                default_directory.display()
            )
        })?;
        let default_directory = default_directory
            .canonicalize()
            .map_err(|error| format!("could not resolve default notes directory: {error}"))?;
        let config_path = app_data.join(STORAGE_FILE_NAME);
        let state = if config_path.exists() {
            let bytes = fs::read(&config_path)
                .map_err(|error| format!("could not read notes storage settings: {error}"))?;
            let state: PersistedStorage = serde_json::from_slice(&bytes)
                .map_err(|error| format!("invalid notes storage settings: {error}"))?;
            validate_persisted(&state)?;
            state
        } else {
            PersistedStorage::default()
        };
        Ok(Self {
            default_directory,
            config_path,
            state: Mutex::new(state),
        })
    }

    pub fn settings(&self) -> NotesStorageSettings {
        let state = self.state.lock().unwrap_or_else(|lock| lock.into_inner());
        settings_for(&self.default_directory, &state)
    }

    pub fn active_root(&self) -> NoteRoot {
        let state = self.state.lock().unwrap_or_else(|lock| lock.into_inner());
        if state.active_source == "local" {
            return NoteRoot {
                source: "local".into(),
                path: self.default_directory.clone(),
            };
        }
        state
            .custom_roots
            .iter()
            .find(|root| root.source == state.active_source)
            .map(|root| NoteRoot {
                source: root.source.clone(),
                path: root.path.clone(),
            })
            .unwrap_or_else(|| NoteRoot {
                source: "local".into(),
                path: self.default_directory.clone(),
            })
    }

    pub fn note_roots(&self) -> Vec<NoteRoot> {
        let state = self.state.lock().unwrap_or_else(|lock| lock.into_inner());
        let mut roots = vec![NoteRoot {
            source: "local".into(),
            path: self.default_directory.clone(),
        }];
        roots.extend(state.custom_roots.iter().map(|root| NoteRoot {
            source: root.source.clone(),
            path: root.path.clone(),
        }));
        roots
    }

    pub fn select_directory(
        &self,
        directory: Option<&Path>,
    ) -> Result<NotesStorageSettings, String> {
        let selected = directory.map(validate_selected_directory).transpose()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "notes storage settings are unavailable".to_string())?;
        let mut next = state.clone();
        next.active_source = match selected {
            None => "local".into(),
            Some(ref path) if path == &self.default_directory => "local".into(),
            Some(ref path) => next
                .custom_roots
                .iter()
                .find(|root| root.path == *path)
                .map(|root| root.source.clone())
                .unwrap_or_else(|| {
                    let source = format!("storage-{}", Uuid::new_v4().simple());
                    next.custom_roots.push(CustomRoot {
                        source: source.clone(),
                        path: path.clone(),
                    });
                    source
                }),
        };
        self.write_state(&next)?;
        *state = next;
        Ok(settings_for(&self.default_directory, &state))
    }

    fn write_state(&self, state: &PersistedStorage) -> Result<(), String> {
        let parent = self
            .config_path
            .parent()
            .ok_or_else(|| "notes storage settings path has no parent".to_string())?;
        fs::create_dir_all(parent)
            .map_err(|error| format!("could not create notes settings folder: {error}"))?;
        let mut temporary = NamedTempFile::new_in(parent)
            .map_err(|error| format!("could not stage notes settings: {error}"))?;
        serde_json::to_writer_pretty(&mut temporary, state)
            .map_err(|error| format!("could not encode notes settings: {error}"))?;
        temporary
            .write_all(b"\n")
            .and_then(|_| temporary.as_file().sync_all())
            .map_err(|error| format!("could not finish notes settings: {error}"))?;
        temporary
            .persist(&self.config_path)
            .map_err(|error| format!("could not save notes settings: {}", error.error))?;
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NoteMetadata {
    version: u32,
    source: String,
    created_at: String,
    updated_at: String,
    #[serde(default)]
    meeting_id: Option<String>,
    #[serde(default)]
    meeting_title: Option<String>,
    #[serde(default)]
    agent_turn_id: Option<String>,
}

#[derive(Clone, Debug)]
pub struct NoteStore {
    roots: Arc<RwLock<Vec<NoteRoot>>>,
}

impl NoteStore {
    pub fn new(roots: Vec<NoteRoot>) -> Result<Self, String> {
        validate_roots(&roots)?;
        Ok(Self {
            roots: Arc::new(RwLock::new(roots)),
        })
    }

    pub fn set_roots(&self, roots: Vec<NoteRoot>) -> Result<(), String> {
        validate_roots(&roots)?;
        *self
            .roots
            .write()
            .map_err(|_| "note folders are unavailable".to_string())? = roots;
        Ok(())
    }

    pub fn list(&self, query: Option<&str>) -> Result<Vec<NoteDocument>, String> {
        let needle = query
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_lowercase);
        let roots = self
            .roots
            .read()
            .map_err(|_| "note folders are unavailable".to_string())?
            .clone();
        let mut notes = Vec::new();
        let mut seen = HashSet::new();
        for root in roots {
            if !root.path.exists() {
                continue;
            }
            let entries = fs::read_dir(&root.path).map_err(|error| {
                format!(
                    "could not read notes folder {}: {error}",
                    root.path.display()
                )
            })?;
            for entry in entries.flatten() {
                let path = entry.path();
                if !is_markdown_file(&path) || entry.file_type().is_ok_and(|kind| kind.is_symlink())
                {
                    continue;
                }
                let canonical = path.canonicalize().unwrap_or_else(|_| path.clone());
                if !seen.insert(canonical) {
                    continue;
                }
                let note = match read_note_file(&root, &path) {
                    Ok(note) => note,
                    Err(_) => continue,
                };
                if note.meeting_id.is_none() {
                    continue;
                }
                if needle.as_deref().is_some_and(|needle| {
                    !format!(
                        "{}\n{}\n{}",
                        note.title,
                        note.body,
                        note.meeting_title.as_deref().unwrap_or_default()
                    )
                    .to_lowercase()
                    .contains(needle)
                }) {
                    continue;
                }
                notes.push(note);
            }
        }
        notes.sort_by(|left, right| {
            note_timestamp(&right.updated_at)
                .cmp(&note_timestamp(&left.updated_at))
                .then_with(|| right.id.cmp(&left.id))
        });
        Ok(notes)
    }

    pub fn read(&self, id: &str) -> Result<NoteDocument, String> {
        let (root, path) = self.resolve(id)?;
        read_note_file(&root, &path)
    }

    pub fn save_manual(
        &self,
        active_root: &NoteRoot,
        id: Option<&str>,
        meeting: &MeetingSummary,
        title: &str,
        body: &str,
    ) -> Result<NoteDocument, String> {
        let title = validate_title(title)?;
        validate_body(body)?;
        let now = Local::now().to_rfc3339();
        let (root, path, mut metadata) = if let Some(id) = id {
            let (root, path) = self.resolve(id)?;
            let existing = read_note_file(&root, &path)?;
            (
                root,
                path,
                NoteMetadata {
                    version: 1,
                    source: existing.source,
                    created_at: existing.created_at,
                    updated_at: now.clone(),
                    meeting_id: Some(meeting.id.clone()),
                    meeting_title: meeting.title.clone(),
                    agent_turn_id: existing.agent_turn_id,
                },
            )
        } else {
            self.ensure_active_root(active_root)?;
            let file_name = format!(
                "note-{}-{}.md",
                Local::now().format("%Y%m%d-%H%M%S"),
                &Uuid::new_v4().simple().to_string()[..8]
            );
            (
                active_root.clone(),
                active_root.path.join(file_name),
                NoteMetadata {
                    version: 1,
                    source: "manual".into(),
                    created_at: now.clone(),
                    updated_at: now.clone(),
                    meeting_id: Some(meeting.id.clone()),
                    meeting_title: meeting.title.clone(),
                    agent_turn_id: None,
                },
            )
        };
        metadata.updated_at = now;
        write_note_file(&root, &path, &title, body, &metadata)
    }

    pub fn save_agent(
        &self,
        active_root: &NoteRoot,
        meeting: &MeetingSummary,
        turn: &PersistedAgentTurn,
    ) -> Result<NoteDocument, String> {
        self.ensure_active_root(active_root)?;
        let title = agent_note_title(&turn.question);
        validate_body(&turn.answer)?;
        let now = Local::now().to_rfc3339();
        let file_name = format!(
            "note-{}-{}.md",
            Local::now().format("%Y%m%d-%H%M%S"),
            &Uuid::new_v4().simple().to_string()[..8]
        );
        let metadata = NoteMetadata {
            version: 1,
            source: "agent".into(),
            created_at: now.clone(),
            updated_at: now,
            meeting_id: Some(meeting.id.clone()),
            meeting_title: meeting.title.clone(),
            agent_turn_id: Some(turn.id.clone()),
        };
        write_note_file(
            active_root,
            &active_root.path.join(file_name),
            &title,
            &turn.answer,
            &metadata,
        )
    }

    pub fn delete(&self, id: &str) -> Result<(), String> {
        let (_, path) = self.resolve(id)?;
        fs::remove_file(&path)
            .map_err(|error| format!("could not delete note {}: {error}", path.display()))
    }

    fn ensure_active_root(&self, active_root: &NoteRoot) -> Result<(), String> {
        let roots = self
            .roots
            .read()
            .map_err(|_| "note folders are unavailable".to_string())?;
        if roots.iter().any(|root| root == active_root) {
            Ok(())
        } else {
            Err("selected notes folder is unavailable".into())
        }
    }

    fn resolve(&self, id: &str) -> Result<(NoteRoot, PathBuf), String> {
        let (source, file_name) = validate_note_id(id)?;
        let roots = self
            .roots
            .read()
            .map_err(|_| "note folders are unavailable".to_string())?;
        let root = roots
            .iter()
            .find(|root| root.source == source)
            .cloned()
            .ok_or_else(|| "invalid note source".to_string())?;
        for entry in fs::read_dir(&root.path)
            .map_err(|error| format!("could not read notes folder: {error}"))?
            .flatten()
        {
            if entry.file_name().to_str() == Some(file_name)
                && entry.file_type().is_ok_and(|kind| kind.is_file())
            {
                return Ok((root, entry.path()));
            }
        }
        Err(format!("note not found: {id}"))
    }
}

pub fn materialize_legacy_agent_notes(
    notes: &NoteStore,
    storage: &NotesStorage,
    meeting_state: &MeetingStateStore,
    meetings: &[MeetingSummary],
) -> Result<usize, String> {
    let mut created = 0;
    for meeting in meetings {
        for turn in meeting_state.list(&meeting.id)? {
            if !turn.saved_as_note {
                continue;
            }
            if turn
                .note_id
                .as_deref()
                .is_some_and(|note_id| notes.read(note_id).is_ok())
            {
                continue;
            }
            let note = notes.save_agent(&storage.active_root(), meeting, &turn)?;
            if let Err(error) = meeting_state.link_saved_note(&meeting.id, &turn.id, Some(&note.id))
            {
                let _ = notes.delete(&note.id);
                return Err(error);
            }
            created += 1;
        }
    }
    Ok(created)
}

fn write_note_file(
    root: &NoteRoot,
    path: &Path,
    title: &str,
    body: &str,
    metadata: &NoteMetadata,
) -> Result<NoteDocument, String> {
    fs::create_dir_all(&root.path)
        .map_err(|error| format!("could not create notes folder: {error}"))?;
    let encoded = serde_json::to_string(metadata)
        .map_err(|error| format!("could not encode note metadata: {error}"))?;
    let markdown = format!("{NOTE_PREFIX}{encoded} -->\n# {title}\n\n{body}\n");
    if markdown.len() as u64 > MAX_NOTE_BYTES {
        return Err("note is too large to save".into());
    }
    let mut temporary = NamedTempFile::new_in(&root.path)
        .map_err(|error| format!("could not stage note: {error}"))?;
    temporary
        .write_all(markdown.as_bytes())
        .and_then(|_| temporary.flush())
        .and_then(|_| temporary.as_file().sync_all())
        .map_err(|error| format!("could not write note: {error}"))?;
    temporary
        .persist(path)
        .map_err(|error| format!("could not save note: {}", error.error))?;
    read_note_file(root, path)
}

fn read_note_file(root: &NoteRoot, path: &Path) -> Result<NoteDocument, String> {
    let metadata =
        fs::metadata(path).map_err(|error| format!("could not inspect note: {error}"))?;
    if metadata.len() > MAX_NOTE_BYTES {
        return Err("note is too large to open".into());
    }
    let markdown =
        fs::read_to_string(path).map_err(|error| format!("could not read note: {error}"))?;
    let mut lines = markdown.lines();
    let first = lines.next().unwrap_or_default();
    let (note_metadata, content) = if first.starts_with(NOTE_PREFIX) && first.ends_with(" -->") {
        let encoded = first
            .strip_prefix(NOTE_PREFIX)
            .and_then(|value| value.strip_suffix(" -->"))
            .ok_or_else(|| "invalid note metadata".to_string())?;
        let parsed: NoteMetadata = serde_json::from_str(encoded)
            .map_err(|error| format!("invalid note metadata: {error}"))?;
        (Some(parsed), lines.collect::<Vec<_>>().join("\n"))
    } else {
        (None, markdown.clone())
    };
    let content = content.trim_start_matches('\n');
    let (title, body) = split_title_body(content, path);
    let modified = metadata.modified().ok().map(DateTime::<Local>::from);
    let fallback_time = modified.unwrap_or_else(Local::now).to_rfc3339();
    let note_metadata = note_metadata.unwrap_or(NoteMetadata {
        version: 1,
        source: "manual".into(),
        created_at: fallback_time.clone(),
        updated_at: fallback_time,
        meeting_id: None,
        meeting_title: None,
        agent_turn_id: None,
    });
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| "invalid note filename".to_string())?;
    Ok(NoteDocument {
        id: format!("{}:{file_name}", root.source),
        title,
        body,
        source: note_metadata.source,
        created_at: note_metadata.created_at,
        updated_at: note_metadata.updated_at,
        path: path.to_string_lossy().into_owned(),
        meeting_id: note_metadata.meeting_id,
        meeting_title: note_metadata.meeting_title,
        agent_turn_id: note_metadata.agent_turn_id,
    })
}

fn split_title_body(content: &str, path: &Path) -> (String, String) {
    let mut lines = content.lines();
    let first = lines.next().unwrap_or_default();
    if let Some(title) = first.strip_prefix("# ") {
        return (
            title.trim().to_string(),
            lines.collect::<Vec<_>>().join("\n").trim().to_string(),
        );
    }
    let title = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Untitled note")
        .to_string();
    (title, content.trim().to_string())
}

fn validate_title(title: &str) -> Result<String, String> {
    let title = title.trim();
    if title.is_empty() {
        return Err("note title cannot be empty".into());
    }
    if title.chars().count() > MAX_TITLE_CHARS || title.chars().any(char::is_control) {
        return Err(format!(
            "note title must be one line with at most {MAX_TITLE_CHARS} characters"
        ));
    }
    Ok(title.into())
}

fn agent_note_title(question: &str) -> String {
    let normalized = question
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    let trimmed = normalized.trim();
    let title = if trimmed.is_empty() {
        "Saved Agent answer"
    } else {
        trimmed
    };
    title.chars().take(MAX_TITLE_CHARS).collect()
}

fn validate_body(body: &str) -> Result<(), String> {
    if body.len() as u64 > MAX_NOTE_BYTES {
        return Err("note is too large to save".into());
    }
    Ok(())
}

fn validate_note_id(id: &str) -> Result<(&str, &str), String> {
    let (source, file_name) = id
        .split_once(':')
        .ok_or_else(|| "invalid note id".to_string())?;
    if !is_storage_source(source)
        || file_name.is_empty()
        || !file_name.ends_with(".md")
        || file_name.contains(['/', '\\', ':'])
        || file_name.chars().any(char::is_control)
    {
        return Err("invalid note id".into());
    }
    Ok((source, file_name))
}

fn is_markdown_file(path: &Path) -> bool {
    path.extension().and_then(|value| value.to_str()) == Some("md")
}

fn note_timestamp(value: &str) -> i64 {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.timestamp_millis())
        .unwrap_or(i64::MIN)
}

fn validate_roots(roots: &[NoteRoot]) -> Result<(), String> {
    if roots.is_empty() || roots.iter().all(|root| root.source != "local") {
        return Err("note folders must include the default folder".into());
    }
    let mut sources = HashSet::new();
    let mut paths = HashSet::new();
    if roots.iter().any(|root| {
        !is_storage_source(&root.source)
            || !root.path.is_absolute()
            || !sources.insert(root.source.as_str())
            || !paths.insert(root.path.as_path())
    }) {
        return Err("note folders contain an invalid or duplicate folder".into());
    }
    Ok(())
}

fn settings_for(default_directory: &Path, state: &PersistedStorage) -> NotesStorageSettings {
    let selected_directory = if state.active_source == "local" {
        default_directory.to_path_buf()
    } else {
        state
            .custom_roots
            .iter()
            .find(|root| root.source == state.active_source)
            .map(|root| root.path.clone())
            .unwrap_or_else(|| default_directory.to_path_buf())
    };
    NotesStorageSettings {
        using_default: selected_directory == default_directory,
        default_directory: default_directory.into(),
        selected_directory,
    }
}

fn validate_selected_directory(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err("notes folder must be an absolute path".into());
    }
    if !fs::metadata(path).is_ok_and(|metadata| metadata.is_dir()) {
        return Err("notes storage location must be an existing folder".into());
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("could not resolve notes folder: {error}"))?;
    let probe = canonical.join(format!(".arco-write-test-{}", Uuid::new_v4().simple()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .map_err(|error| format!("notes folder is not writable: {error}"))?;
    let result = file.write_all(b"Arco");
    drop(file);
    let _ = fs::remove_file(&probe);
    result.map_err(|error| format!("notes folder is not writable: {error}"))?;
    Ok(canonical)
}

fn validate_persisted(state: &PersistedStorage) -> Result<(), String> {
    if state.schema_version != STORAGE_SCHEMA_VERSION {
        return Err(format!(
            "unsupported notes storage settings version {}",
            state.schema_version
        ));
    }
    let roots = state
        .custom_roots
        .iter()
        .map(|root| NoteRoot {
            source: root.source.clone(),
            path: root.path.clone(),
        })
        .collect::<Vec<_>>();
    let mut sources = HashSet::new();
    let mut paths = HashSet::new();
    if roots.iter().any(|root| {
        !is_storage_source(&root.source)
            || root.source == "local"
            || !root.path.is_absolute()
            || !sources.insert(root.source.as_str())
            || !paths.insert(root.path.as_path())
    }) {
        return Err("notes storage settings contain an invalid or duplicate folder".into());
    }
    if state.active_source != "local"
        && !roots.iter().any(|root| root.source == state.active_source)
    {
        return Err("notes storage settings select an unknown folder".into());
    }
    Ok(())
}
