use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DoubaoCredentials {
    pub app_id: String,
    pub access_token: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoubaoCredentialStatus {
    pub configured: bool,
    pub verified: bool,
    pub message: Option<String>,
}

impl DoubaoCredentialStatus {
    fn missing() -> Self {
        Self {
            configured: false,
            verified: false,
            message: None,
        }
    }
}

pub fn normalize_credentials(
    app_id: &str,
    access_token: &str,
) -> Result<DoubaoCredentials, String> {
    let app_id = app_id.trim();
    let access_token = access_token.trim();
    if app_id.is_empty() {
        return Err("Paste a Doubao API Key or App ID first.".into());
    }
    if app_id.chars().any(char::is_whitespace) || access_token.chars().any(char::is_whitespace) {
        return Err("Doubao credentials cannot contain spaces.".into());
    }
    if app_id.len() < 4 {
        return Err("This does not look like a complete Doubao App ID.".into());
    }
    if !access_token.is_empty() && access_token.len() < 10 {
        return Err("This does not look like a complete Doubao Access Token.".into());
    }
    Ok(DoubaoCredentials {
        app_id: app_id.into(),
        access_token: access_token.into(),
    })
}

pub fn status() -> DoubaoCredentialStatus {
    match load_credentials() {
        Ok(Some(_)) => DoubaoCredentialStatus {
            configured: true,
            verified: true,
            message: None,
        },
        Ok(None) => DoubaoCredentialStatus::missing(),
        Err(error) => DoubaoCredentialStatus {
            configured: false,
            verified: false,
            message: Some(error),
        },
    }
}

pub async fn save_verified_credentials(
    app_id: &str,
    access_token: &str,
) -> Result<DoubaoCredentialStatus, String> {
    let credentials = normalize_credentials(app_id, access_token)?;
    crate::doubao::verify_credentials(&credentials.app_id, &credentials.access_token).await?;
    store_credentials(&credentials)?;
    Ok(DoubaoCredentialStatus {
        configured: true,
        verified: true,
        message: Some("Doubao is ready.".into()),
    })
}

pub fn remove_credentials() -> Result<DoubaoCredentialStatus, String> {
    crate::credential_store::remove("doubao")?;
    Ok(DoubaoCredentialStatus::missing())
}

pub fn load_credentials() -> Result<Option<DoubaoCredentials>, String> {
    crate::credential_store::CredentialStore::discover()?.load("doubao")
}

fn store_credentials(credentials: &DoubaoCredentials) -> Result<(), String> {
    crate::credential_store::CredentialStore::discover()?.save("doubao", credentials)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalization_accepts_a_new_console_api_key_without_echoing_secrets() {
        let credentials = normalize_credentials("  api-key-123456789  ", "").unwrap();
        assert_eq!(credentials.app_id, "api-key-123456789");
        assert_eq!(credentials.access_token, "");

        let credentials = normalize_credentials("  app-123  ", "  token-123456789  ").unwrap();
        assert_eq!(credentials.app_id, "app-123");
        assert_eq!(credentials.access_token, "token-123456789");

        let raw = "sensitive token";
        let error = normalize_credentials("app-123", raw).unwrap_err();
        assert!(!error.contains(raw));
    }

    #[test]
    fn status_serialization_never_contains_credentials() {
        assert_eq!(
            serde_json::to_string(&DoubaoCredentialStatus::missing()).unwrap(),
            r#"{"configured":false,"verified":false,"message":null}"#
        );
    }
}
