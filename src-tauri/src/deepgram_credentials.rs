use serde::Serialize;

const KEYCHAIN_SERVICE: &str = "app.arco.desktop.deepgram.v2";
const LEGACY_KEYCHAIN_SERVICE: &str = "app.arco.desktop.deepgram";
const KEYCHAIN_ACCOUNT: &str = "api-key";
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
    #[cfg(target_os = "macos")]
    {
        if has_keychain_item(KEYCHAIN_SERVICE)? {
            return Ok(true);
        }
        if !has_keychain_item(LEGACY_KEYCHAIN_SERVICE)? {
            return Ok(false);
        }
        load_api_key().map(|key| key.is_some())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(false)
    }
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
    #[cfg(target_os = "macos")]
    {
        for service in [KEYCHAIN_SERVICE, LEGACY_KEYCHAIN_SERVICE] {
            match security_framework::passwords::delete_generic_password(service, KEYCHAIN_ACCOUNT)
            {
                Ok(()) => {}
                Err(error) if error.code() == -25300 => {}
                Err(error) => {
                    return Err(format!(
                        "could not remove the Deepgram key from Keychain: {error}"
                    ));
                }
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        return Err("Arco stores Deepgram credentials in macOS Keychain.".into());
    }
    Ok(DeepgramCredentialStatus::missing())
}

pub fn load_api_key() -> Result<Option<String>, String> {
    #[cfg(target_os = "macos")]
    {
        let bytes = load_with_legacy_migration(
            || load_keychain_item(KEYCHAIN_SERVICE),
            || load_keychain_item(LEGACY_KEYCHAIN_SERVICE),
            |bytes| store_keychain_item(KEYCHAIN_SERVICE, bytes),
            || delete_keychain_item(LEGACY_KEYCHAIN_SERVICE),
        )?;
        bytes
            .map(String::from_utf8)
            .transpose()
            .map_err(|_| "the Deepgram credential in Keychain is not valid UTF-8".into())
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

fn store_api_key(key: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        store_keychain_item(KEYCHAIN_SERVICE, key.as_bytes())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = key;
        Err("Arco stores Deepgram credentials in macOS Keychain.".into())
    }
}

fn load_with_legacy_migration<LoadCurrent, LoadLegacy, StoreCurrent, DeleteLegacy>(
    load_current: LoadCurrent,
    load_legacy: LoadLegacy,
    store_current: StoreCurrent,
    delete_legacy: DeleteLegacy,
) -> Result<Option<Vec<u8>>, String>
where
    LoadCurrent: FnOnce() -> Result<Option<Vec<u8>>, String>,
    LoadLegacy: FnOnce() -> Result<Option<Vec<u8>>, String>,
    StoreCurrent: FnOnce(&[u8]) -> Result<(), String>,
    DeleteLegacy: FnOnce() -> Result<(), String>,
{
    if let Some(bytes) = load_current()? {
        return Ok(Some(bytes));
    }
    let Some(bytes) = load_legacy()? else {
        return Ok(None);
    };
    store_current(&bytes)?;
    let _ = delete_legacy();
    Ok(Some(bytes))
}

#[cfg(target_os = "macos")]
fn has_keychain_item(service: &str) -> Result<bool, String> {
    use security_framework::item::{ItemClass, ItemSearchOptions};

    let result = ItemSearchOptions::new()
        .class(ItemClass::generic_password())
        .service(service)
        .account(KEYCHAIN_ACCOUNT)
        .load_attributes(true)
        .search();
    match result {
        Ok(items) => Ok(!items.is_empty()),
        Err(error) if error.code() == -25300 => Ok(false),
        Err(error) => Err(format!(
            "could not inspect the Deepgram credential in Keychain: {error}"
        )),
    }
}

#[cfg(target_os = "macos")]
fn load_keychain_item(service: &str) -> Result<Option<Vec<u8>>, String> {
    match security_framework::passwords::get_generic_password(service, KEYCHAIN_ACCOUNT) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(error) => Err(format!(
            "could not read the Deepgram credential from Keychain: {error}"
        )),
    }
}

#[cfg(target_os = "macos")]
fn store_keychain_item(service: &str, bytes: &[u8]) -> Result<(), String> {
    security_framework::passwords::set_generic_password(service, KEYCHAIN_ACCOUNT, bytes)
        .map_err(|error| format!("could not save the Deepgram key to Keychain: {error}"))
}

#[cfg(target_os = "macos")]
fn delete_keychain_item(service: &str) -> Result<(), String> {
    match security_framework::passwords::delete_generic_password(service, KEYCHAIN_ACCOUNT) {
        Ok(()) => Ok(()),
        Err(error) if error.code() == -25300 => Ok(()),
        Err(error) => Err(format!(
            "could not remove the legacy Deepgram key from Keychain: {error}"
        )),
    }
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
    fn current_keychain_entry_is_used_without_touching_the_legacy_item() {
        use std::cell::Cell;

        let legacy_touched = Cell::new(false);
        let value = load_with_legacy_migration(
            || Ok(Some(b"current-secret".to_vec())),
            || {
                legacy_touched.set(true);
                Ok(Some(b"legacy-secret".to_vec()))
            },
            |_| panic!("current credential must not be rewritten"),
            || panic!("legacy credential must not be deleted"),
        )
        .unwrap();

        assert_eq!(value, Some(b"current-secret".to_vec()));
        assert!(!legacy_touched.get());
    }

    #[test]
    fn legacy_keychain_entry_is_copied_before_the_old_acl_is_deleted() {
        use std::cell::RefCell;

        let events = RefCell::new(Vec::new());
        let value = load_with_legacy_migration(
            || Ok(None),
            || Ok(Some(b"legacy-secret".to_vec())),
            |bytes| {
                assert_eq!(bytes, b"legacy-secret");
                events.borrow_mut().push("stored-current");
                Ok(())
            },
            || {
                events.borrow_mut().push("deleted-legacy");
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(value, Some(b"legacy-secret".to_vec()));
        assert_eq!(*events.borrow(), ["stored-current", "deleted-legacy"]);
    }

    #[test]
    fn failed_migration_never_deletes_the_only_saved_key() {
        use std::cell::Cell;

        let deleted = Cell::new(false);
        let error = load_with_legacy_migration(
            || Ok(None),
            || Ok(Some(b"legacy-secret".to_vec())),
            |_| Err("new item failed".into()),
            || {
                deleted.set(true);
                Ok(())
            },
        )
        .unwrap_err();

        assert_eq!(error, "new item failed");
        assert!(!deleted.get());
    }
}
