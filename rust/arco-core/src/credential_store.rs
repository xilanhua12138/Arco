//! Local credential storage. The app never reads or writes macOS Keychain.
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

const MAX_BYTES: u64 = 1024 * 1024;

#[derive(Serialize, Deserialize)]
struct Document {
    version: u32,
    providers: BTreeMap<String, Value>,
}

impl Default for Document {
    fn default() -> Self {
        Self {
            version: 1,
            providers: BTreeMap::new(),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApiKey {
    api_key: String,
}

pub(crate) struct CredentialStore {
    directory: PathBuf,
}

impl CredentialStore {
    pub(crate) fn discover() -> Result<Self, String> {
        Ok(Self {
            directory: crate::paths::home_dir()?.join(".arco"),
        })
    }

    pub(crate) fn load<T: DeserializeOwned>(&self, provider: &str) -> Result<Option<T>, String> {
        if !self
            .directory
            .try_exists()
            .map_err(|_| "Cannot inspect credential directory")?
        {
            return Ok(None);
        }
        let _lock = self.lock()?;
        self.read()?
            .providers
            .remove(provider)
            .map(serde_json::from_value)
            .transpose()
            .map_err(|_| "Invalid provider entry in ~/.arco/credentials.json".into())
    }

    pub(crate) fn save<T: Serialize>(&self, provider: &str, value: &T) -> Result<(), String> {
        let value = serde_json::to_value(value).map_err(|_| "Cannot encode credentials")?;
        self.update(|document| {
            document.providers.insert(provider.into(), value);
        })
    }

    pub(crate) fn remove(&self, provider: &str) -> Result<(), String> {
        self.update(|document| {
            document.providers.remove(provider);
        })
    }

    fn lock(&self) -> Result<File, String> {
        match fs::DirBuilder::new().mode(0o700).create(&self.directory) {
            Ok(()) => (),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
            Err(_) => return Err("Cannot create ~/.arco credential directory".into()),
        }
        let metadata = fs::symlink_metadata(&self.directory)
            .map_err(|_| "Cannot inspect credential directory")?;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err("Credential directory must be an owned directory, not a symlink".into());
        }
        fs::set_permissions(&self.directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| "Cannot restrict credential directory permissions")?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.directory.join("credentials.lock"))
            .map_err(|_| "Cannot open credential file lock")?;
        restrict_file(&file)?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err("Cannot lock credential file".into());
        }
        Ok(file) // Closing the file releases the cross-process lock.
    }

    fn read(&self) -> Result<Document, String> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(self.directory.join("credentials.json"))
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(Document::default())
            }
            Err(_) => return Err("Cannot open ~/.arco/credentials.json".into()),
        };
        restrict_file(&file)?;
        let mut bytes = Vec::new();
        file.take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "Cannot read credentials.json")?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err("Credential file is too large".into());
        }
        // Never include serde's error text: malformed input could contain secrets.
        let document: Document = serde_json::from_slice(&bytes)
            .map_err(|_| "Invalid ~/.arco/credentials.json; existing file was preserved")?;
        if document.version != 1 {
            return Err("Unsupported credential file version".into());
        }
        Ok(document)
    }

    fn update(&self, change: impl FnOnce(&mut Document)) -> Result<(), String> {
        let _lock = self.lock()?;
        let mut document = self.read()?;
        change(&mut document);
        let bytes =
            serde_json::to_vec_pretty(&document).map_err(|_| "Cannot encode credential file")?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err("Credential file is too large".into());
        }
        let mut temporary = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| "Cannot create private credential file")?;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| "Cannot restrict credential file permissions")?;
        temporary
            .write_all(&bytes)
            .map_err(|_| "Cannot write credential file")?;
        temporary
            .as_file()
            .sync_all()
            .map_err(|_| "Cannot sync credential file")?;
        temporary
            .persist(self.directory.join("credentials.json"))
            .map_err(|_| "Cannot replace credential file")?;
        File::open(&self.directory)
            .and_then(|file| file.sync_all())
            .map_err(|_| "Cannot sync credential directory")?;
        Ok(())
    }
}

fn restrict_file(file: &File) -> Result<(), String> {
    let metadata = file
        .metadata()
        .map_err(|_| "Cannot inspect credential file")?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(
            "Credential file must be a regular file owned by the current user without hard links"
                .into(),
        );
    }
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|_| "Cannot restrict credential file permissions".into())
}

pub(crate) fn load_api_key(provider: &str) -> Result<Option<String>, String> {
    CredentialStore::discover()?
        .load::<ApiKey>(provider)
        .map(|value| value.map(|key| key.api_key))
}
pub(crate) fn save_api_key(provider: &str, key: &str) -> Result<(), String> {
    CredentialStore::discover()?.save(
        provider,
        &ApiKey {
            api_key: key.into(),
        },
    )
}
pub(crate) fn remove(provider: &str) -> Result<(), String> {
    CredentialStore::discover()?.remove(provider)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn store() -> (tempfile::TempDir, CredentialStore) {
        let temp = tempfile::tempdir().unwrap();
        let store = CredentialStore {
            directory: temp.path().join(".arco"),
        };
        (temp, store)
    }
    #[test]
    fn credentials_survive_reopen_and_other_provider_changes() {
        let (_temp, store) = store();
        assert!(store.load::<Value>("doubao").unwrap().is_none());
        let pair = serde_json::json!({"appId":"fixture-app", "accessToken":"fixture-token"});
        store.save("doubao", &pair).unwrap();
        store
            .save(
                "gptLive",
                &serde_json::json!({"refreshToken":"fixture-refresh"}),
            )
            .unwrap();
        store.remove("gptLive").unwrap();
        let reopened = CredentialStore {
            directory: store.directory.clone(),
        };
        assert_eq!(reopened.load::<Value>("doubao").unwrap(), Some(pair));
        assert!(reopened.load::<Value>("gptLive").unwrap().is_none());
        assert_eq!(
            fs::metadata(&store.directory).unwrap().mode() & 0o777,
            0o700
        );
        assert_eq!(
            fs::metadata(store.directory.join("credentials.json"))
                .unwrap()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn corrupt_or_future_files_are_preserved_without_echoing_secrets() {
        let (_temp, store) = store();
        store.save("deepgram", &"fixture").unwrap();
        for raw in [
            "super-secret-broken-json",
            r#"{"version":99,"providers":{}}"#,
        ] {
            fs::write(store.directory.join("credentials.json"), raw).unwrap();
            let error = store.save("elevenLabs", &"replacement").unwrap_err();
            assert!(!error.contains("super-secret"));
            assert_eq!(
                fs::read_to_string(store.directory.join("credentials.json")).unwrap(),
                raw
            );
        }
    }
    #[test]
    fn symlink_and_hardlink_targets_are_never_overwritten() {
        let (temp, store) = store();
        fs::create_dir(&store.directory).unwrap();
        let target = temp.path().join("unrelated");
        fs::write(&target, "keep-this").unwrap();
        let path = store.directory.join("credentials.json");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert!(store.save("deepgram", &"fixture").is_err());
        fs::remove_file(&path).unwrap();
        fs::hard_link(&target, &path).unwrap();
        assert!(store.save("deepgram", &"fixture").is_err());
        assert_eq!(fs::read_to_string(target).unwrap(), "keep-this");
    }
    #[test]
    fn concurrent_writers_preserve_all_providers() {
        let (_temp, store) = store();
        let workers: Vec<_> = (0..12)
            .map(|index| {
                let directory = store.directory.clone();
                std::thread::spawn(move || {
                    CredentialStore { directory }
                        .save(&index.to_string(), &index)
                        .unwrap()
                })
            })
            .collect();
        for worker in workers {
            worker.join().unwrap();
        }
        for index in 0..12 {
            assert_eq!(store.load::<i32>(&index.to_string()).unwrap(), Some(index));
        }
    }
}
