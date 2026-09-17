use serde::Serialize;

const ELEVENLABS_USER_URL: &str = "https://api.elevenlabs.io/v1/user";

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
    Ok(load_api_key()?.is_some())
}

pub fn save_verified_api_key(value: &str) -> Result<ElevenLabsCredentialStatus, String> {
    let key = normalize_api_key(value)?;
    validate_api_key(&key)?;
    store_api_key(&key)?;
    Ok(ElevenLabsCredentialStatus {
        configured: true,
        verified: true,
        message: Some("ElevenLabs is ready.".into()),
    })
}

pub fn remove_api_key() -> Result<ElevenLabsCredentialStatus, String> {
    crate::credential_store::remove("elevenLabs")?;
    Ok(ElevenLabsCredentialStatus::missing())
}

pub fn load_api_key() -> Result<Option<String>, String> {
    crate::credential_store::load_api_key("elevenLabs")
}

fn store_api_key(key: &str) -> Result<(), String> {
    crate::credential_store::save_api_key("elevenLabs", key)
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
