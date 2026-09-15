use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tempfile::NamedTempFile;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioArchiveConfig {
    pub enabled: bool,
    pub directory: PathBuf,
    pub max_bytes: u64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioArchiveSettings {
    #[serde(flatten)]
    pub config: AudioArchiveConfig,
    pub default_directory: PathBuf,
    pub used_bytes: u64,
    pub status: Option<Value>,
}

pub struct AudioArchiveStorage {
    app_data: PathBuf,
    default_directory: PathBuf,
    write_lock: Mutex<()>,
}

impl AudioArchiveStorage {
    pub fn new(app_data: PathBuf, home: &Path) -> Self {
        Self {
            app_data,
            default_directory: home.join("Music/Arco/Recordings"),
            write_lock: Mutex::new(()),
        }
    }

    fn config(&self) -> Result<AudioArchiveConfig, String> {
        let path = self.app_data.join("audio-archive.json");
        if !path.exists() {
            return Ok(AudioArchiveConfig {
                enabled: true,
                directory: self.default_directory.clone(),
                max_bytes: 10_000_000_000,
            });
        }
        let config: AudioArchiveConfig =
            serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
                .map_err(|e| format!("Invalid audio storage settings: {e}"))?;
        validate(&config)?;
        Ok(config)
    }

    pub fn settings(&self) -> Result<AudioArchiveSettings, String> {
        let config = self.config()?;
        let used_bytes = archive_size(&config.directory)?;
        let status = fs::read(self.app_data.join("audio-archive-status.json"))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok());
        Ok(AudioArchiveSettings {
            config,
            default_directory: self.default_directory.clone(),
            used_bytes,
            status,
        })
    }

    fn directories(&self) -> Vec<PathBuf> {
        let mut roots: Vec<PathBuf> = fs::read(self.app_data.join("audio-archive-roots.json"))
            .ok()
            .and_then(|v| serde_json::from_slice(&v).ok())
            .unwrap_or_default();
        roots.push(self.default_directory.clone());
        if let Ok(config) = self.config() {
            roots.push(config.directory);
        }
        roots.sort();
        roots.dedup();
        roots
    }

    /// Resolve only Arco-owned files for a meeting already validated by MeetingStore.
    /// Numbered chunks keep their original offsets even after quota eviction.
    pub fn recording(&self, meeting: &crate::models::MeetingSummary) -> Result<Value, String> {
        let meeting_start = chrono::DateTime::parse_from_rfc3339(&meeting.started_at)
            .map_err(|e| e.to_string())?
            .timestamp_millis();
        let mut recordings = Vec::new();
        for root in self.directories() {
            let entries = match fs::read_dir(&root) {
                Ok(entries) => entries,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return Err(format!("Could not read recordings: {e}")),
            };
            for entry in entries.flatten() {
                if !entry.file_type().is_ok_and(|t| t.is_dir()) {
                    continue;
                }
                let marker = entry.path().join("recording.json");
                if fs::symlink_metadata(&marker).is_ok_and(|m| m.file_type().is_symlink()) {
                    continue;
                }
                let Some(meta) = fs::read(&marker)
                    .ok()
                    .and_then(|v| serde_json::from_slice::<Value>(&v).ok())
                else {
                    continue;
                };
                if meta["owner"] != "app.arco.audio-archive" {
                    continue;
                }
                let same_path = meta["transcript"].as_str().is_some_and(|p| {
                    p == meeting.path
                        || Path::new(p)
                            .canonicalize()
                            .ok()
                            .zip(Path::new(&meeting.path).canonicalize().ok())
                            .is_some_and(|(a, b)| a == b)
                });
                if !same_path && meta["meetingID"] != meeting.id {
                    continue;
                }
                let origin = meta["sessionStartedAtUnix"]
                    .as_f64()
                    .filter(|v| v.is_finite())
                    .map(|v| (v * 1000.0).round() as i64);
                let created = meta["startedAt"]
                    .as_str()
                    .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
                    .map(|v| v.timestamp_millis())
                    .unwrap_or(meeting_start);
                recordings.push((created, origin, meta, entry.path()));
            }
        }
        recordings.sort_by_key(|r| r.0);
        let mut chunks = Vec::new();
        for (position, (created, origin, meta, folder)) in recordings.into_iter().enumerate() {
            // Legacy first captures started on the meeting sample clock; their
            // marker's creation time includes helper startup and must not shift audio.
            let offset = origin.unwrap_or(if position == 0 {
                meeting_start
            } else {
                created
            }) - meeting_start;
            let span = meta["segmentDurationMs"]
                .as_i64()
                .filter(|v| *v > 0)
                .unwrap_or(300_000);
            for file in fs::read_dir(folder).map_err(|e| e.to_string())?.flatten() {
                if !file.file_type().is_ok_and(|t| t.is_file()) {
                    continue;
                }
                let name = file.file_name().to_string_lossy().into_owned();
                let Some(index) = name
                    .strip_prefix("audio-")
                    .and_then(|v| v.strip_suffix(".m4a"))
                    .filter(|v| v.len() == 6 && v.bytes().all(|b| b.is_ascii_digit()))
                    .and_then(|v| v.parse::<i64>().ok())
                    .filter(|v| *v > 0)
                else {
                    continue;
                };
                chunks.push(serde_json::json!({ "path": file.path(), "startMs": (offset + (index-1)*span).max(0) }));
            }
        }
        chunks.sort_by_key(|c| c["startMs"].as_i64().unwrap_or(0));
        chunks.dedup_by(|a, b| a["path"] == b["path"]);
        Ok(serde_json::json!({ "meetingId": meeting.id, "chunks": chunks }))
    }

    pub fn update(
        &self,
        enabled: bool,
        directory: Option<&Path>,
        max_bytes: u64,
    ) -> Result<AudioArchiveSettings, String> {
        let _guard = self
            .write_lock
            .lock()
            .map_err(|_| "Audio storage settings unavailable")?;
        let mut config = AudioArchiveConfig {
            enabled,
            directory: directory.unwrap_or(&self.default_directory).to_path_buf(),
            max_bytes,
        };
        validate(&config)?;
        fs::create_dir_all(&config.directory)
            .map_err(|e| format!("Could not create audio folder: {e}"))?;
        config.directory = config.directory.canonicalize().map_err(|e| e.to_string())?;
        // Check writability before replacing a valid configuration.
        let _probe = NamedTempFile::new_in(&config.directory)
            .map_err(|e| format!("Audio folder is not writable: {e}"))?;
        fs::create_dir_all(&self.app_data).map_err(|e| e.to_string())?;
        let mut roots = self.directories();
        roots.push(config.directory.clone());
        roots.sort();
        roots.dedup();
        let mut roots_file = NamedTempFile::new_in(&self.app_data).map_err(|e| e.to_string())?;
        serde_json::to_writer(&mut roots_file, &roots).map_err(|e| e.to_string())?;
        roots_file
            .persist(self.app_data.join("audio-archive-roots.json"))
            .map_err(|e| e.to_string())?;
        let mut staged = NamedTempFile::new_in(&self.app_data).map_err(|e| e.to_string())?;
        serde_json::to_writer_pretty(&mut staged, &config).map_err(|e| e.to_string())?;
        staged.as_file().sync_all().map_err(|e| e.to_string())?;
        staged
            .persist(self.app_data.join("audio-archive.json"))
            .map_err(|e| e.to_string())?;
        self.settings()
    }
}

fn validate(config: &AudioArchiveConfig) -> Result<(), String> {
    if !config.directory.is_absolute() {
        return Err("Audio folder must be an absolute path".into());
    }
    if !(1_000_000_000..=1_000_000_000_000).contains(&config.max_bytes) {
        return Err("Audio storage limit must be between 1 and 1000 GB".into());
    }
    Ok(())
}

fn archive_size(directory: &Path) -> Result<u64, String> {
    if !directory.exists() {
        return Ok(0);
    }
    let mut total: u64 = 0;
    for entry in fs::read_dir(directory).map_err(|e| format!("Could not read audio folder: {e}"))? {
        let entry = entry.map_err(|e| e.to_string())?;
        if !entry.file_type().map_err(|e| e.to_string())?.is_dir() {
            continue;
        }
        let marker = entry.path().join("recording.json");
        let owned = fs::read(marker)
            .ok()
            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
            .is_some_and(|v| v["owner"] == "app.arco.audio-archive");
        if !owned {
            continue;
        }
        for file in fs::read_dir(entry.path()).map_err(|e| e.to_string())? {
            let file = file.map_err(|e| e.to_string())?;
            if file.file_type().map_err(|e| e.to_string())?.is_file() {
                total = total.saturating_add(file.metadata().map_err(|e| e.to_string())?.len());
            }
        }
    }
    Ok(total)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lookup_preserves_evicted_offsets_and_previous_directories() {
        let root = tempfile::tempdir().unwrap();
        let store = AudioArchiveStorage::new(root.path().join("app"), root.path());
        let old = root.path().join("old");
        store.update(true, Some(&old), 1_000_000_000).unwrap();
        let transcript = root.path().join("transcript-20260915-120000.md");
        fs::write(&transcript, "# Meeting Transcript\n\n> Started: 2026-09-15 12:00:00\n\n**[12:00:01] Remote 1:** hello\n").unwrap();
        let summary = crate::meetings::parse_meeting(&transcript, "local", None)
            .unwrap()
            .summary;
        let folder = old.join("recording");
        fs::create_dir(&folder).unwrap();
        fs::write(folder.join("recording.json"), serde_json::to_vec(&serde_json::json!({"owner":"app.arco.audio-archive", "meetingID": summary.id, "transcript": summary.path})).unwrap()).unwrap();
        fs::write(folder.join("audio-000003.m4a"), b"audio").unwrap();
        fs::write(folder.join("audio-other.m4a"), b"ignore").unwrap();
        #[cfg(unix)]
        std::os::unix::fs::symlink(&transcript, folder.join("audio-000004.m4a")).unwrap();
        store
            .update(true, Some(&root.path().join("new")), 1_000_000_000)
            .unwrap();
        let recording = store.recording(&summary).unwrap();
        let chunks = recording["chunks"].as_array().unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0]["startMs"], 600000);
        let mut other = summary.clone();
        other.id = "other".into();
        other.path = "other".into();
        assert!(store.recording(&other).unwrap()["chunks"]
            .as_array()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn defaults_and_saved_settings_survive_reload() {
        let root = tempfile::tempdir().unwrap();
        let store = AudioArchiveStorage::new(root.path().join("app"), root.path());
        let defaults = store.settings().unwrap();
        assert!(defaults.config.enabled);
        assert_eq!(defaults.config.max_bytes, 10_000_000_000);
        assert_eq!(
            defaults.config.directory,
            root.path().join("Music/Arco/Recordings")
        );
        assert_eq!(defaults.used_bytes, 0);
        let directory = root.path().join("custom");
        store
            .update(false, Some(&directory), 5_000_000_000)
            .unwrap();
        let loaded = AudioArchiveStorage::new(root.path().join("app"), root.path())
            .settings()
            .unwrap();
        assert!(!loaded.config.enabled);
        assert_eq!(loaded.config.directory, directory.canonicalize().unwrap());
        assert_eq!(loaded.config.max_bytes, 5_000_000_000);
    }
    #[test]
    fn invalid_limits_and_unusable_paths_preserve_previous_settings() {
        let root = tempfile::tempdir().unwrap();
        let store = AudioArchiveStorage::new(root.path().join("app"), root.path());
        store.update(true, None, 10_000_000_000).unwrap();
        for limit in [0, 999_999_999, 1_000_000_000_001, u64::MAX] {
            assert!(store
                .update(true, None, limit)
                .unwrap_err()
                .contains("between 1 and 1000 GB"));
        }
        assert!(store
            .update(true, Some(Path::new("relative")), 10_000_000_000)
            .is_err());
        let file = root.path().join("file");
        fs::write(&file, b"keep").unwrap();
        assert!(store.update(true, Some(&file), 10_000_000_000).is_err());
        assert_eq!(fs::read(file).unwrap(), b"keep");
        assert_eq!(store.settings().unwrap().config.max_bytes, 10_000_000_000);
    }
}
