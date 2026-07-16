use serde::Serialize;
use std::sync::{Mutex, OnceLock};

const KEYCHAIN_SERVICE: &str = "app.arco.desktop.elevenlabs.v1";
const KEYCHAIN_ACCOUNT: &str = "api-key";
const ELEVENLABS_USER_URL: &str = "https://api.elevenlabs.io/v1/user";

static SESSION_API_KEY: OnceLock<Mutex<Option<String>>> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ElevenLabsCredentialStatus {
    pub configured: bool,
    pub verified: bool,
    pub message: Option<String>,
}

impl ElevenLabsCredentialStatus {
    fn missing() -> Self {
        Self {
            configured: false,
            verified: false,
            message: None,
        }
    }
}

pub fn normalize_api_key(value: &str) -> Result<String, String> {
    let key = value.trim();
    if key.is_empty() {
        return Err("Paste an ElevenLabs API key first.".into());
    }
    if key.chars().any(char::is_whitespace) {
        return Err("The ElevenLabs API key cannot contain spaces.".into());
    }
    if key.len() < 20 {
        return Err("This does not look like a complete ElevenLabs API key.".into());
    }
    Ok(key.to_string())
}

pub fn status() -> ElevenLabsCredentialStatus {
    status_from_presence(has_api_key())
}

fn status_from_presence(presence: Result<bool, String>) -> ElevenLabsCredentialStatus {
    match presence {
        Ok(true) => ElevenLabsCredentialStatus {
            configured: true,
            verified: true,
            message: None,
        },
        Ok(false) => ElevenLabsCredentialStatus::missing(),
        Err(error) => ElevenLabsCredentialStatus {
            configured: false,
            verified: false,
            message: Some(error),
        },
    }
}

fn has_api_key() -> Result<bool, String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::item::{ItemClass, ItemSearchOptions};

        let result = ItemSearchOptions::new()
            .class(ItemClass::generic_password())
            .service(KEYCHAIN_SERVICE)
            .account(KEYCHAIN_ACCOUNT)
            .load_attributes(true)
            .search();
        match result {
            Ok(items) => Ok(!items.is_empty()),
            Err(error) if error.code() == -25300 => Ok(false),
            Err(error) => Err(format!(
                "could not inspect the ElevenLabs credential in Keychain: {error}"
            )),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(false)
    }
}

pub fn save_verified_api_key(value: &str) -> Result<ElevenLabsCredentialStatus, String> {
    let key = normalize_api_key(value)?;
    validate_api_key(&key)?;
    store_api_key(&key)?;
    cache_api_key(Some(key))?;
    Ok(ElevenLabsCredentialStatus {
        configured: true,
        verified: true,
        message: Some("ElevenLabs is ready.".into()),
    })
}

pub fn remove_api_key() -> Result<ElevenLabsCredentialStatus, String> {
    cache_api_key(None)?;
    #[cfg(target_os = "macos")]
    {
        match security_framework::passwords::delete_generic_password(
            KEYCHAIN_SERVICE,
            KEYCHAIN_ACCOUNT,
        ) {
            Ok(()) => {}
            Err(error) if error.code() == -25300 => {}
            Err(error) => {
                return Err(format!(
                    "could not remove the ElevenLabs key from Keychain: {error}"
                ));
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        return Err("Arco stores ElevenLabs credentials in macOS Keychain.".into());
    }
    Ok(ElevenLabsCredentialStatus::missing())
}

pub fn load_api_key() -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        let mut cached = session_api_key()
            .lock()
            .map_err(|_| "the in-memory ElevenLabs credential cache is unavailable".to_string())?;
        if cached.is_some() {
            return Ok(cached.clone());
        }
        let loaded = match security_framework::passwords::get_generic_password(
            KEYCHAIN_SERVICE,
            KEYCHAIN_ACCOUNT,
        ) {
            Ok(bytes) => Some(
                String::from_utf8(bytes)
                    .map_err(|_| "the ElevenLabs credential in Keychain is not valid UTF-8")?,
            ),
            Err(error) if error.code() == -25300 => None,
            Err(error) => {
                return Err(format!(
                    "could not read the ElevenLabs credential from Keychain: {error}"
                ));
            }
        };
        if loaded.is_some() {
            *cached = loaded.clone();
        }
        Ok(loaded)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

fn store_api_key(key: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::os::macos::keychain::SecKeychain;

        let keychain = SecKeychain::default()
            .map_err(|error| format!("could not open the login Keychain: {error}"))?;
        keychain
            .set_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, key.as_bytes())
            .map_err(|error| format!("could not save the ElevenLabs key to Keychain: {error}"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = key;
        Err("Arco stores ElevenLabs credentials in macOS Keychain.".into())
    }
}

fn session_api_key() -> &'static Mutex<Option<String>> {
    SESSION_API_KEY.get_or_init(|| Mutex::new(None))
}

fn cache_api_key(value: Option<String>) -> Result<(), String> {
    let mut cached = session_api_key()
        .lock()
        .map_err(|_| "the in-memory ElevenLabs credential cache is unavailable".to_string())?;
    *cached = value;
    Ok(())
}

fn validate_api_key(key: &str) -> Result<(), String> {
    match ureq::get(ELEVENLABS_USER_URL).set("xi-api-key", key).call() {
        Ok(response) if response.status() == 200 => Ok(()),
        Ok(response) => Err(format!(
            "ElevenLabs could not verify this key (HTTP {}).",
            response.status()
        )),
        Err(ureq::Error::Status(401 | 403, _)) => {
            Err("ElevenLabs rejected this API key. Check it and try again.".into())
        }
        Err(ureq::Error::Status(status, _)) => Err(format!(
            "ElevenLabs could not verify this key (HTTP {status})."
        )),
        Err(ureq::Error::Transport(error)) => Err(format!(
            "Could not reach ElevenLabs to verify the key: {error}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_key_normalization_never_echoes_the_secret_in_errors() {
        let raw = "  sk_0123456789abcdefghijklmnopqrstuvwxyz  ";
        assert_eq!(normalize_api_key(raw).unwrap(), raw.trim());
        let error = normalize_api_key("short key").unwrap_err();
        assert!(!error.contains("short key"));
    }

    #[test]
    fn status_serialization_never_contains_a_credential() {
        assert_eq!(
            serde_json::to_string(&ElevenLabsCredentialStatus::missing()).unwrap(),
            r#"{"configured":false,"verified":false,"message":null}"#
        );
        assert_eq!(
            status_from_presence(Err("metadata lookup failed".into())).message,
            Some("metadata lookup failed".into())
        );
    }
}
