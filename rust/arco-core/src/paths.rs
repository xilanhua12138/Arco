use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct AppPaths {
    pub home: PathBuf,
    pub app_data: PathBuf,
    pub transcripts: PathBuf,
    pub notes: PathBuf,
    pub legacy_transcripts: PathBuf,
    pub native_dir: PathBuf,
}

impl AppPaths {
    pub fn discover(resource_dir: Option<&Path>) -> Result<Self, String> {
        let home = home_dir()?;
        let app_data = std::env::var_os("ARCO_APP_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| {
                home.join("Library")
                    .join("Application Support")
                    .join("Arco")
            });
        let native_dir = std::env::var_os("ARCO_NATIVE_DIR")
            .map(PathBuf::from)
            .or_else(|| resource_dir.map(|path| path.join("native")))
            .filter(|path| {
                path.join("arco-deepgram-transcriber").exists()
                    || path.join("runtime/arco-deepgram-transcriber").exists()
                    || path.join("arco-elevenlabs-transcriber").exists()
                    || path.join("runtime/arco-elevenlabs-transcriber").exists()
                    || path.join("recorder").exists()
            })
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .parent()
                    .and_then(Path::parent)
                    .expect("rust/arco-core has a repository root")
                    .join("native")
            });
        Ok(Self {
            transcripts: app_data.join("transcripts"),
            notes: app_data.join("notes"),
            legacy_transcripts: home.join(".claude").join("meeting-transcripts"),
            home,
            app_data,
            native_dir,
        })
    }
}

pub fn home_dir() -> Result<PathBuf, String> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| !path.as_os_str().is_empty())
        .ok_or_else(|| "HOME is not set; Arco cannot locate local transcripts or agent CLIs".into())
}
