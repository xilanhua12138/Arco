use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tempfile::NamedTempFile;
use uuid::Uuid;

const STORAGE_SCHEMA_VERSION: u32 = 1;
const STORAGE_FILE_NAME: &str = "transcript-storage.json";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeetingRoot {
    pub source: String,
    pub path: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptStorageSettings {
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
pub struct TranscriptStorage {
    default_directory: PathBuf,
    config_path: PathBuf,
    state: Mutex<PersistedStorage>,
}

impl TranscriptStorage {
    pub fn load(app_data: PathBuf, default_directory: PathBuf) -> Result<Self, String> {
        if !default_directory.is_absolute() {
            return Err("default transcript directory must be absolute".into());
        }
        fs::create_dir_all(&default_directory).map_err(|error| {
            format!(
                "could not create default transcript directory {}: {error}",
                default_directory.display()
            )
        })?;
        let default_directory = default_directory.canonicalize().map_err(|error| {
            format!(
                "could not resolve default transcript directory {}: {error}",
                default_directory.display()
            )
        })?;
        let config_path = app_data.join(STORAGE_FILE_NAME);
        let state = if config_path.exists() {
            let bytes = fs::read(&config_path)
                .map_err(|error| format!("could not read transcript storage settings: {error}"))?;
            let state: PersistedStorage = serde_json::from_slice(&bytes)
                .map_err(|error| format!("invalid transcript storage settings: {error}"))?;
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

    pub fn settings(&self) -> TranscriptStorageSettings {
        let state = self.state.lock().unwrap_or_else(|lock| lock.into_inner());
        settings_for(&self.default_directory, &state)
    }

    pub fn active_root(&self) -> MeetingRoot {
        let state = self.state.lock().unwrap_or_else(|lock| lock.into_inner());
        if state.active_source == "local" {
            return MeetingRoot {
                source: "local".into(),
                path: self.default_directory.clone(),
            };
        }
        state
            .custom_roots
            .iter()
            .find(|root| root.source == state.active_source)
            .map(|root| MeetingRoot {
                source: root.source.clone(),
                path: root.path.clone(),
            })
            .unwrap_or_else(|| MeetingRoot {
                source: "local".into(),
                path: self.default_directory.clone(),
            })
    }

    pub fn meeting_roots(&self) -> Vec<MeetingRoot> {
        let state = self.state.lock().unwrap_or_else(|lock| lock.into_inner());
        let mut roots = vec![MeetingRoot {
            source: "local".into(),
            path: self.default_directory.clone(),
        }];
        roots.extend(state.custom_roots.iter().map(|root| MeetingRoot {
            source: root.source.clone(),
            path: root.path.clone(),
        }));
        roots
    }

    pub fn select_directory(
        &self,
        directory: Option<&Path>,
    ) -> Result<TranscriptStorageSettings, String> {
        let selected = directory.map(validate_selected_directory).transpose()?;
        let mut state = self
            .state
            .lock()
            .map_err(|_| "transcript storage settings are unavailable".to_string())?;
        let mut next = state.clone();
        let next_source = match selected {
            None => "local".to_string(),
            Some(ref path) if path == &self.default_directory => "local".to_string(),
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
        next.active_source = next_source;
        self.write_state(&next)?;
        *state = next;
        Ok(settings_for(&self.default_directory, &state))
    }

    fn write_state(&self, state: &PersistedStorage) -> Result<(), String> {
        let parent = self
            .config_path
            .parent()
            .ok_or_else(|| "transcript storage settings path has no parent".to_string())?;
        fs::create_dir_all(parent).map_err(|error| {
            format!("could not create transcript storage settings folder: {error}")
        })?;
        let mut temporary = NamedTempFile::new_in(parent)
            .map_err(|error| format!("could not stage transcript storage settings: {error}"))?;
        serde_json::to_writer_pretty(&mut temporary, state)
            .map_err(|error| format!("could not encode transcript storage settings: {error}"))?;
        temporary
            .write_all(b"\n")
            .map_err(|error| format!("could not finish transcript storage settings: {error}"))?;
        temporary
            .as_file()
            .sync_all()
            .map_err(|error| format!("could not sync transcript storage settings: {error}"))?;
        temporary.persist(&self.config_path).map_err(|error| {
            format!(
                "could not save transcript storage settings: {}",
                error.error
            )
        })?;
        Ok(())
    }
}

fn settings_for(default_directory: &Path, state: &PersistedStorage) -> TranscriptStorageSettings {
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
    TranscriptStorageSettings {
        default_directory: default_directory.to_path_buf(),
        using_default: selected_directory == default_directory,
        selected_directory,
    }
}

fn validate_selected_directory(path: &Path) -> Result<PathBuf, String> {
    if !path.is_absolute() {
        return Err("transcript storage folder must be an absolute path".into());
    }
    let metadata = fs::metadata(path).map_err(|error| {
        format!(
            "could not open transcript storage folder {}: {error}",
            path.display()
        )
    })?;
    if !metadata.is_dir() {
        return Err("transcript storage location must be a folder".into());
    }
    let canonical = path
        .canonicalize()
        .map_err(|error| format!("could not resolve transcript storage folder: {error}"))?;
    let probe = canonical.join(format!(".arco-write-test-{}", Uuid::new_v4().simple()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .map_err(|error| format!("transcript storage folder is not writable: {error}"))?;
    if let Err(error) = file.write_all(b"Arco") {
        drop(file);
        let _ = fs::remove_file(&probe);
        return Err(format!(
            "transcript storage folder is not writable: {error}"
        ));
    }
    drop(file);
    fs::remove_file(&probe)
        .map_err(|error| format!("could not finish transcript storage write check: {error}"))?;
    Ok(canonical)
}

fn validate_persisted(state: &PersistedStorage) -> Result<(), String> {
    if state.schema_version != STORAGE_SCHEMA_VERSION {
        return Err(format!(
            "unsupported transcript storage settings version {}",
            state.schema_version
        ));
    }
    let mut sources = std::collections::HashSet::new();
    let mut paths = std::collections::HashSet::new();
    for root in &state.custom_roots {
        if !is_storage_source(&root.source)
            || !root.path.is_absolute()
            || !sources.insert(root.source.as_str())
            || !paths.insert(root.path.as_path())
        {
            return Err(
                "transcript storage settings contain an invalid or duplicate folder".into(),
            );
        }
    }
    if state.active_source != "local"
        && !state
            .custom_roots
            .iter()
            .any(|root| root.source == state.active_source)
    {
        return Err("transcript storage settings select an unknown folder".into());
    }
    Ok(())
}

pub fn is_storage_source(source: &str) -> bool {
    source == "local"
        || source.strip_prefix("storage-").is_some_and(|suffix| {
            suffix.len() == 32
                && suffix
                    .chars()
                    .all(|character| character.is_ascii_hexdigit())
        })
}
