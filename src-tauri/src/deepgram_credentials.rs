use serde::Serialize;
use std::sync::{Mutex, OnceLock};

const KEYCHAIN_SERVICE: &str = "app.arco.desktop.deepgram.v3";
const PREVIOUS_KEYCHAIN_SERVICE: &str = "app.arco.desktop.deepgram.v2";
const LEGACY_KEYCHAIN_SERVICE: &str = "app.arco.desktop.deepgram";
const KEYCHAIN_ACCOUNT: &str = "api-key";
const DEEPGRAM_AUTH_URL: &str = "https://api.deepgram.com/v1/auth/token";

static SESSION_API_KEY: OnceLock<Mutex<Option<String>>> = OnceLock::new();

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
        for service in [
            KEYCHAIN_SERVICE,
            PREVIOUS_KEYCHAIN_SERVICE,
            LEGACY_KEYCHAIN_SERVICE,
        ] {
            if has_keychain_item(service)? {
                return Ok(true);
            }
        }
        Ok(false)
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
    cache_api_key(Some(key))?;
    Ok(DeepgramCredentialStatus {
        configured: true,
        verified: true,
        message: Some("Deepgram is ready.".into()),
    })
}

pub fn remove_api_key() -> Result<DeepgramCredentialStatus, String> {
    cache_api_key(None)?;
    #[cfg(target_os = "macos")]
    {
        for service in [
            KEYCHAIN_SERVICE,
            PREVIOUS_KEYCHAIN_SERVICE,
            LEGACY_KEYCHAIN_SERVICE,
        ] {
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
        load_cached_api_key(session_api_key(), || {
            let bytes = load_with_legacy_migration(
                load_current_keychain_item,
                || load_keychain_item(PREVIOUS_KEYCHAIN_SERVICE),
                || load_keychain_item(LEGACY_KEYCHAIN_SERVICE),
                store_current_keychain_item,
            )?;
            bytes
                .map(String::from_utf8)
                .transpose()
                .map_err(|_| "the Deepgram credential in Keychain is not valid UTF-8".into())
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}

fn store_api_key(key: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        store_current_keychain_item(key.as_bytes())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = key;
        Err("Arco stores Deepgram credentials in macOS Keychain.".into())
    }
}

fn session_api_key() -> &'static Mutex<Option<String>> {
    SESSION_API_KEY.get_or_init(|| Mutex::new(None))
}

fn cache_api_key(value: Option<String>) -> Result<(), String> {
    let mut cached = session_api_key()
        .lock()
        .map_err(|_| "the in-memory Deepgram credential cache is unavailable".to_string())?;
    *cached = value;
    Ok(())
}

fn load_cached_api_key<Load>(
    cache: &Mutex<Option<String>>,
    load: Load,
) -> Result<Option<String>, String>
where
    Load: FnOnce() -> Result<Option<String>, String>,
{
    let mut cached = cache
        .lock()
        .map_err(|_| "the in-memory Deepgram credential cache is unavailable".to_string())?;
    if cached.is_some() {
        return Ok(cached.clone());
    }
    let loaded = load()?;
    if loaded.is_some() {
        *cached = loaded.clone();
    }
    Ok(loaded)
}

fn load_with_legacy_migration<LoadCurrent, LoadPrevious, LoadLegacy, StoreCurrent>(
    load_current: LoadCurrent,
    load_previous: LoadPrevious,
    load_legacy: LoadLegacy,
    store_current: StoreCurrent,
) -> Result<Option<Vec<u8>>, String>
where
    LoadCurrent: FnOnce() -> Result<Option<Vec<u8>>, String>,
    LoadPrevious: FnOnce() -> Result<Option<Vec<u8>>, String>,
    LoadLegacy: FnOnce() -> Result<Option<Vec<u8>>, String>,
    StoreCurrent: FnOnce(&[u8]) -> Result<(), String>,
{
    if let Some(bytes) = load_current()? {
        return Ok(Some(bytes));
    }
    let bytes = match load_previous()? {
        Some(bytes) => bytes,
        None => match load_legacy()? {
            Some(bytes) => bytes,
            None => return Ok(None),
        },
    };
    store_current(&bytes)?;
    Ok(Some(bytes))
}

#[cfg(target_os = "macos")]
fn load_current_keychain_item() -> Result<Option<Vec<u8>>, String> {
    use security_framework::os::macos::keychain::SecKeychain;

    let keychain = SecKeychain::default()
        .map_err(|error| format!("could not open the login Keychain: {error}"))?;
    match keychain.find_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT) {
        Ok((password, _item)) => Ok(Some(password.to_vec())),
        Err(error) if error.code() == -25300 => Ok(None),
        Err(error) => Err(format!(
            "could not read the Deepgram credential from Keychain: {error}"
        )),
    }
}

#[cfg(target_os = "macos")]
fn store_current_keychain_item(bytes: &[u8]) -> Result<(), String> {
    use security_framework::os::macos::keychain::SecKeychain;

    let keychain = SecKeychain::default()
        .map_err(|error| format!("could not open the login Keychain: {error}"))?;
    keychain
        .set_generic_password(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT, bytes)
        .map_err(|error| format!("could not save the Deepgram key to Keychain: {error}"))
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

// The v2 entry used the SecItem compatibility shim. The v3 entry is created
// explicitly in the login Keychain by the signed Arco process, so its default
// ACL trusts Arco. Older entries remain only as migration fallbacks and are
// removed when the user explicitly clears the credential.

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

        let previous_touched = Cell::new(false);
        let legacy_touched = Cell::new(false);
        let value = load_with_legacy_migration(
            || Ok(Some(b"current-secret".to_vec())),
            || {
                previous_touched.set(true);
                Ok(Some(b"previous-secret".to_vec()))
            },
            || {
                legacy_touched.set(true);
                Ok(Some(b"legacy-secret".to_vec()))
            },
            |_| panic!("current credential must not be rewritten"),
        )
        .unwrap();

        assert_eq!(value, Some(b"current-secret".to_vec()));
        assert!(!previous_touched.get());
        assert!(!legacy_touched.get());
    }

    #[test]
    fn previous_keychain_entry_is_copied_without_touching_the_oldest_acl() {
        use std::cell::RefCell;

        let events = RefCell::new(Vec::new());
        let value = load_with_legacy_migration(
            || Ok(None),
            || Ok(Some(b"previous-secret".to_vec())),
            || panic!("the oldest Keychain item must not be opened"),
            |bytes| {
                assert_eq!(bytes, b"previous-secret");
                events.borrow_mut().push("stored-current");
                Ok(())
            },
        )
        .unwrap();

        assert_eq!(value, Some(b"previous-secret".to_vec()));
        assert_eq!(*events.borrow(), ["stored-current"]);
    }

    #[test]
    fn failed_migration_leaves_the_only_saved_key_untouched() {
        let error = load_with_legacy_migration(
            || Ok(None),
            || Ok(None),
            || Ok(Some(b"legacy-secret".to_vec())),
            |_| Err("new item failed".into()),
        )
        .unwrap_err();

        assert_eq!(error, "new item failed");
    }

    #[test]
    fn second_capture_reuses_the_session_credential_without_reopening_keychain() {
        use std::sync::Mutex;

        let cache = Mutex::new(None);
        let reads = std::cell::Cell::new(0);

        let first = load_cached_api_key(&cache, || {
            reads.set(reads.get() + 1);
            Ok(Some("session-secret".into()))
        })
        .unwrap();
        let second = load_cached_api_key(&cache, || {
            reads.set(reads.get() + 1);
            Ok(Some("unexpected-second-read".into()))
        })
        .unwrap();

        assert_eq!(first.as_deref(), Some("session-secret"));
        assert_eq!(second.as_deref(), Some("session-secret"));
        assert_eq!(
            reads.get(),
            1,
            "Keychain must only be opened once per app session"
        );
    }

    #[test]
    fn preview_packaging_unregisters_non_installed_app_copies() {
        let packaging = include_str!("../../native/package-local-app.sh");

        assert!(
            packaging.contains("unregister_app \"$APP\"")
                && packaging.contains("unregister_app \"$MOUNT_POINT/Arco.app\""),
            "build and mounted-DMG app copies must not remain registered as alternate Arco identities"
        );
    }
}
