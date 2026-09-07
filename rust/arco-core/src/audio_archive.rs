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
