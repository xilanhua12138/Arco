use serde::Serialize;
use std::sync::{Mutex, OnceLock};

const KEYCHAIN_SERVICE: &str = "app.arco.desktop.doubao.v1";
const APP_ID_ACCOUNT: &str = "app-id";
const ACCESS_TOKEN_ACCOUNT: &str = "access-token";

static SESSION_CREDENTIALS: OnceLock<Mutex<Option<DoubaoCredentials>>> = OnceLock::new();

#[derive(Clone, Debug, PartialEq, Eq)]
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
    cache_credentials(Some(credentials))?;
    Ok(DoubaoCredentialStatus {
        configured: true,
        verified: true,
        message: Some("Doubao is ready.".into()),
    })
}

pub fn remove_credentials() -> Result<DoubaoCredentialStatus, String> {
    cache_credentials(None)?;
    #[cfg(target_os = "macos")]
    {
        for account in [APP_ID_ACCOUNT, ACCESS_TOKEN_ACCOUNT] {
            match security_framework::passwords::delete_generic_password(KEYCHAIN_SERVICE, account)
            {
                Ok(()) => {}
                Err(error) if error.code() == -25300 => {}
                Err(error) => {
                    return Err(format!(
                        "could not remove Doubao credentials from Keychain: {error}"
                    ));
                }
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        return Err("Arco stores Doubao credentials in macOS Keychain.".into());
    }
    Ok(DoubaoCredentialStatus::missing())
}

pub fn load_credentials() -> Result<Option<DoubaoCredentials>, String> {
    let mut cache = session_credentials()
        .lock()
        .map_err(|_| "the in-memory Doubao credential cache is unavailable".to_string())?;
    if cache.is_some() {
        return Ok(cache.clone());
    }
    #[cfg(target_os = "macos")]
    {
        let app_id = read_keychain(APP_ID_ACCOUNT)?;
        let access_token = read_keychain(ACCESS_TOKEN_ACCOUNT)?;
        let loaded = match (app_id, access_token) {
            (Some(app_id), Some(access_token)) => Some(DoubaoCredentials {
                app_id,
                access_token,
            }),
            (None, None) => None,
            _ => {
                return Err("Doubao credentials in Keychain are incomplete. Remove them and configure Doubao again.".into());
            }
        };
        if loaded.is_some() {
            *cache = loaded.clone();
        }
        Ok(loaded)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

#[cfg(target_os = "macos")]
fn read_keychain(account: &str) -> Result<Option<String>, String> {
    match security_framework::passwords::get_generic_password(KEYCHAIN_SERVICE, account) {
        Ok(bytes) => String::from_utf8(bytes)
            .map(Some)
            .map_err(|_| "a Doubao credential in Keychain is not valid UTF-8".into()),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(error) => Err(format!(
            "could not read Doubao credentials from Keychain: {error}"
        )),
    }
}

fn store_credentials(credentials: &DoubaoCredentials) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use security_framework::os::macos::keychain::SecKeychain;
        let keychain = SecKeychain::default()
            .map_err(|error| format!("could not open the login Keychain: {error}"))?;
        keychain
            .set_generic_password(
                KEYCHAIN_SERVICE,
                APP_ID_ACCOUNT,
                credentials.app_id.as_bytes(),
            )
            .map_err(|error| format!("could not save the Doubao App ID to Keychain: {error}"))?;
        if let Err(error) = keychain.set_generic_password(
            KEYCHAIN_SERVICE,
            ACCESS_TOKEN_ACCOUNT,
            credentials.access_token.as_bytes(),
        ) {
            let _ = security_framework::passwords::delete_generic_password(
                KEYCHAIN_SERVICE,
                APP_ID_ACCOUNT,
            );
            return Err(format!(
                "could not save the Doubao Access Token to Keychain: {error}"
            ));
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = credentials;
        Err("Arco stores Doubao credentials in macOS Keychain.".into())
    }
}

fn session_credentials() -> &'static Mutex<Option<DoubaoCredentials>> {
    SESSION_CREDENTIALS.get_or_init(|| Mutex::new(None))
}

fn cache_credentials(value: Option<DoubaoCredentials>) -> Result<(), String> {
    let mut cache = session_credentials()
        .lock()
        .map_err(|_| "the in-memory Doubao credential cache is unavailable".to_string())?;
    *cache = value;
    Ok(())
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
