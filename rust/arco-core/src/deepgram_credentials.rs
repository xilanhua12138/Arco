use serde::Serialize;

const DEEPGRAM_AUTH_URL: &str = "https://api.deepgram.com/v1/auth/token";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeepgramCredentialStatus {
    pub configured: bool,
    pub verified: bool,
    pub message: Option<String>,
}

impl DeepgramCredentialStatus {
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
        return Err("Paste a Deepgram API key first.".into());
    }
    if key.chars().any(char::is_whitespace) {
        return Err("The Deepgram API key cannot contain spaces.".into());
    }
    if key.len() < 20 {
        return Err("This does not look like a complete Deepgram API key.".into());
    }
    Ok(key.to_string())
}

pub fn status() -> DeepgramCredentialStatus {
    status_from_presence(has_api_key())
}

fn status_from_presence(presence: Result<bool, String>) -> DeepgramCredentialStatus {
    match presence {
        Ok(true) => DeepgramCredentialStatus {
            configured: true,
            verified: true,
            message: None,
        },
        Ok(false) => DeepgramCredentialStatus::missing(),
        Err(error) => DeepgramCredentialStatus {
            configured: false,
            verified: false,
            message: Some(error),
        },
    }
}

fn has_api_key() -> Result<bool, String> {
    Ok(load_api_key()?.is_some())
}

pub fn save_verified_api_key(value: &str) -> Result<DeepgramCredentialStatus, String> {
    let key = normalize_api_key(value)?;
    validate_api_key(&key)?;
    store_api_key(&key)?;
    Ok(DeepgramCredentialStatus {
        configured: true,
        verified: true,
        message: Some("Deepgram is ready.".into()),
    })
}

pub fn remove_api_key() -> Result<DeepgramCredentialStatus, String> {
    crate::credential_store::remove("deepgram")?;
    Ok(DeepgramCredentialStatus::missing())
}

pub fn load_api_key() -> Result<Option<String>, String> {
    crate::credential_store::load_api_key("deepgram")
}

fn store_api_key(key: &str) -> Result<(), String> {
    crate::credential_store::save_api_key("deepgram", key)
}

fn validate_api_key(key: &str) -> Result<(), String> {
    match ureq::get(DEEPGRAM_AUTH_URL)
        .set("Authorization", &format!("Token {key}"))
        .call()
    {
        Ok(response) if response.status() == 200 => Ok(()),
        Ok(response) => Err(format!(
            "Deepgram could not verify this key (HTTP {}).",
            response.status()
        )),
        Err(ureq::Error::Status(401 | 403, _)) => {
            Err("Deepgram rejected this API key. Check it and try again.".into())
        }
        Err(ureq::Error::Status(status, _)) => Err(format!(
            "Deepgram could not verify this key (HTTP {status})."
        )),
        Err(ureq::Error::Transport(error)) => Err(format!(
            "Could not reach Deepgram to verify the key: {error}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn api_key_normalization_trims_without_exposing_the_secret() {
        let raw = "  0123456789abcdef0123456789abcdef  ";
        assert_eq!(normalize_api_key(raw).unwrap(), raw.trim());
        let error = normalize_api_key("short key").unwrap_err();
        assert!(!error.contains("short key"));
    }

    #[test]
    fn missing_status_never_contains_a_credential_value() {
        let status = DeepgramCredentialStatus::missing();
        let json = serde_json::to_string(&status).unwrap();
        assert_eq!(
            json,
            r#"{"configured":false,"verified":false,"message":null}"#
        );
    }

    #[test]
    fn configured_status_is_derived_from_item_presence_without_a_secret_read() {
        let status = status_from_presence(Ok(true));
        assert_eq!(
            status,
            DeepgramCredentialStatus {
                configured: true,
                verified: true,
                message: None,
            }
        );

        assert_eq!(
            status_from_presence(Ok(false)),
            DeepgramCredentialStatus::missing()
        );
        assert_eq!(
            status_from_presence(Err("metadata lookup failed".into())).message,
            Some("metadata lookup failed".into()),
        );
    }

    #[test]
    fn preview_packaging_unregisters_non_installed_app_copies() {
        let packaging = include_str!("../../../native/package-local-app.sh");

        assert!(
            packaging.contains("unregister_app \"$APP\"")
                && packaging.contains("unregister_app \"$MOUNT_POINT/Arco.app\""),
            "build and mounted-DMG app copies must not remain registered as alternate Arco identities"
        );
    }
}
