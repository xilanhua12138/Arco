//! Resolve each destination using the process environment and macOS CFNetwork.
//! No proxy address is injected into global or child-process configuration.
use std::collections::BTreeMap;
use url::Url;

pub fn proxy_for_url(target: &str) -> Result<Option<String>, String> {
    let variables = [
        "HTTPS_PROXY",
        "https_proxy",
        "HTTP_PROXY",
        "http_proxy",
        "ALL_PROXY",
        "all_proxy",
        "WSS_PROXY",
        "wss_proxy",
        "WS_PROXY",
        "ws_proxy",
        "NO_PROXY",
        "no_proxy",
    ]
    .into_iter()
    .filter_map(|key| std::env::var(key).ok().map(|value| (key.into(), value)))
    .collect();
    proxy_with(target, &variables, system_proxy)
}

fn proxy_with(
    target: &str,
    variables: &BTreeMap<String, String>,
    system: impl FnOnce(&str) -> Result<Option<String>, String>,
) -> Result<Option<String>, String> {
    let mut target_url =
        Url::parse(target).map_err(|_| "Invalid network destination".to_string())?;
    let host = target_url
        .host_str()
        .ok_or("Network destination has no host")?;
    if ["no_proxy", "NO_PROXY"]
        .iter()
        .find_map(|key| variables.get(*key))
        .is_some_and(|value| no_proxy_matches(value, host))
    {
        return Ok(None);
    }
    let keys: &[&str] = match target_url.scheme() {
        "https" => &[
            "https_proxy",
            "HTTPS_PROXY",
            "http_proxy",
            "HTTP_PROXY",
            "all_proxy",
            "ALL_PROXY",
        ],
        "wss" => &[
            "wss_proxy",
            "WSS_PROXY",
            "https_proxy",
            "HTTPS_PROXY",
            "http_proxy",
            "HTTP_PROXY",
            "all_proxy",
            "ALL_PROXY",
        ],
        "http" => &["http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"],
        "ws" => &[
            "ws_proxy",
            "WS_PROXY",
            "http_proxy",
            "HTTP_PROXY",
            "all_proxy",
            "ALL_PROXY",
        ],
        _ => return Err("Unsupported network destination scheme".into()),
    };
    if let Some(value) = keys.iter().find_map(|key| variables.get(*key)) {
        return if value.trim().is_empty() {
            Ok(None)
        } else {
            Ok(Some(value.clone()))
        };
    }
    match target_url.scheme() {
        "wss" => {
            let _ = target_url.set_scheme("https");
        }
        "ws" => {
            let _ = target_url.set_scheme("http");
        }
        _ => {}
    }
    system(target_url.as_str())
}

fn no_proxy_matches(value: &str, target_host: &str) -> bool {
    value.split(',').any(|entry| {
        let mut pattern = entry.trim().to_ascii_lowercase();
        if pattern == "*" {
            return true;
        }
        if let Some((host, port)) = pattern.rsplit_once(':') {
            if port.bytes().all(|byte| byte.is_ascii_digit()) {
                pattern = host.to_string();
            }
        }
        let pattern = pattern.strip_prefix("*.").unwrap_or(&pattern);
        let pattern = pattern.strip_prefix('.').unwrap_or(pattern);
        !pattern.is_empty()
            && (target_host.eq_ignore_ascii_case(pattern)
                || target_host
                    .to_ascii_lowercase()
                    .ends_with(&format!(".{pattern}")))
    })
}

#[cfg(target_os = "macos")]
fn system_proxy(target: &str) -> Result<Option<String>, String> {
    macos::resolve(target)
}

#[cfg(not(target_os = "macos"))]
fn system_proxy(_: &str) -> Result<Option<String>, String> {
    Ok(None)
}

/// Configure both OAuth and call creation identically; ureq must not perform a
/// second, different environment lookup after CFNetwork selects a direct route.
pub fn configure_http_agent(
    builder: ureq::AgentBuilder,
    target: &str,
) -> Result<ureq::AgentBuilder, String> {
    let builder = builder.try_proxy_from_env(false);
    match proxy_for_url(target)? {
        Some(proxy) => Ok(builder.proxy(
            ureq::Proxy::new(&proxy)
                .map_err(|_| "Unsupported or invalid HTTP proxy configuration".to_string())?,
        )),
        None => Ok(builder),
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::{
        array::{CFArray, CFArrayRef},
        base::{kCFAllocatorDefault, CFType, TCFType},
        dictionary::{CFDictionary, CFDictionaryRef},
        number::CFNumber,
        string::{CFString, CFStringRef},
        url::{CFURLCreateWithString, CFURLRef, CFURL},
    };
    type Dictionary = CFDictionary<CFString, CFType>;

    #[link(name = "CFNetwork", kind = "framework")]
    extern "C" {
        fn CFNetworkCopySystemProxySettings() -> CFDictionaryRef;
        fn CFNetworkCopyProxiesForURL(url: CFURLRef, settings: CFDictionaryRef) -> CFArrayRef;
        static kCFProxyTypeKey: CFStringRef;
        static kCFProxyHostNameKey: CFStringRef;
        static kCFProxyPortNumberKey: CFStringRef;
        static kCFProxyTypeNone: CFStringRef;
        static kCFProxyTypeHTTP: CFStringRef;
        static kCFProxyTypeHTTPS: CFStringRef;
        static kCFProxyTypeSOCKS: CFStringRef;
    }

    pub(super) fn resolve(target: &str) -> Result<Option<String>, String> {
        unsafe {
            let settings_ref = CFNetworkCopySystemProxySettings();
            if settings_ref.is_null() {
                return Err("macOS proxy settings are unavailable".into());
            }
            let settings: Dictionary = TCFType::wrap_under_create_rule(settings_ref);
            let text = CFString::new(target);
            let url_ref = CFURLCreateWithString(
                kCFAllocatorDefault,
                text.as_concrete_TypeRef(),
                std::ptr::null(),
            );
            if url_ref.is_null() {
                return Err("Invalid system proxy destination".into());
            }
            let url: CFURL = TCFType::wrap_under_create_rule(url_ref);
            let proxies_ref = CFNetworkCopyProxiesForURL(
                url.as_concrete_TypeRef(),
                settings.as_concrete_TypeRef(),
            );
            if proxies_ref.is_null() {
                return Err("macOS could not resolve this proxy route".into());
            }
            let proxies: CFArray<Dictionary> = TCFType::wrap_under_create_rule(proxies_ref);
            let Some(first) = proxies.get(0) else {
                return Ok(None);
            };
            route(&first)
        }
    }

    unsafe fn string(dictionary: &Dictionary, key: CFStringRef) -> Option<CFString> {
        let key = CFString::wrap_under_get_rule(key);
        dictionary.find(&key)?.downcast::<CFString>()
    }

    unsafe fn route(dictionary: &Dictionary) -> Result<Option<String>, String> {
        let kind =
            string(dictionary, kCFProxyTypeKey).ok_or("macOS returned an invalid proxy type")?;
        if kind == CFString::wrap_under_get_rule(kCFProxyTypeNone) {
            return Ok(None);
        }
        // CFNetwork's HTTPS type means HTTP CONNECT for an HTTPS destination,
        // not TLS to the proxy itself (same interpretation as Codex).
        let scheme = if kind == CFString::wrap_under_get_rule(kCFProxyTypeHTTP)
            || kind == CFString::wrap_under_get_rule(kCFProxyTypeHTTPS)
        {
            "http"
        } else if kind == CFString::wrap_under_get_rule(kCFProxyTypeSOCKS) {
            "socks5"
        } else {
            return Err("This GPT Live build does not support automatic proxy scripts (PAC). Use a manual proxy or a direct connection.".into());
        };
        let host = string(dictionary, kCFProxyHostNameKey)
            .ok_or("macOS proxy has no host")?
            .to_string();
        let port_key = CFString::wrap_under_get_rule(kCFProxyPortNumberKey);
        let port = dictionary
            .find(&port_key)
            .and_then(|value| value.downcast::<CFNumber>())
            .and_then(|value| value.to_i64())
            .and_then(|value| u16::try_from(value).ok())
            .filter(|value| *value != 0)
            .ok_or("macOS proxy has an invalid port")?;
        let mut url = url::Url::parse(&format!("{scheme}://localhost")).unwrap();
        url.set_host(Some(&host))
            .map_err(|_| "macOS proxy has an invalid host")?;
        url.set_port(Some(port))
            .map_err(|_| "macOS proxy has an invalid port")?;
        Ok(Some(url.into()))
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn native_direct_and_http_routes_are_decoded() {
            unsafe {
                let key = CFString::wrap_under_get_rule(kCFProxyTypeKey);
                let direct = Dictionary::from_CFType_pairs(&[(
                    key.clone(),
                    CFString::wrap_under_get_rule(kCFProxyTypeNone).as_CFType(),
                )]);
                assert_eq!(route(&direct).unwrap(), None);
                let proxy = Dictionary::from_CFType_pairs(&[
                    (
                        key,
                        CFString::wrap_under_get_rule(kCFProxyTypeHTTP).as_CFType(),
                    ),
                    (
                        CFString::wrap_under_get_rule(kCFProxyHostNameKey),
                        CFString::new("proxy.example.test").as_CFType(),
                    ),
                    (
                        CFString::wrap_under_get_rule(kCFProxyPortNumberKey),
                        CFNumber::from(8080).as_CFType(),
                    ),
                ]);
                assert_eq!(
                    route(&proxy).unwrap(),
                    Some("http://proxy.example.test:8080/".into())
                );
                let secure_destination = Dictionary::from_CFType_pairs(&[
                    (
                        CFString::wrap_under_get_rule(kCFProxyTypeKey),
                        CFString::wrap_under_get_rule(kCFProxyTypeHTTPS).as_CFType(),
                    ),
                    (
                        CFString::wrap_under_get_rule(kCFProxyHostNameKey),
                        CFString::new("proxy.example.test").as_CFType(),
                    ),
                    (
                        CFString::wrap_under_get_rule(kCFProxyPortNumberKey),
                        CFNumber::from(8080).as_CFType(),
                    ),
                ]);
                assert_eq!(
                    route(&secure_destination).unwrap(),
                    Some("http://proxy.example.test:8080/".into())
                );
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn environment_and_empty_overrides_take_priority_without_system_lookup() {
        for value in ["", "http://proxy.test:8080"] {
            let env = BTreeMap::from([("HTTPS_PROXY".into(), value.into())]);
            let actual = proxy_with("https://chatgpt.com/path", &env, |_| {
                panic!("system lookup")
            })
            .unwrap();
            assert_eq!(actual, (!value.is_empty()).then(|| value.into()));
        }
    }
    #[test]
    fn bypasses_apply_to_both_environment_and_system_proxies() {
        for pattern in [
            "*",
            "openai.com",
            ".openai.com",
            "*.openai.com",
            "api.openai.com:443",
        ] {
            let env = BTreeMap::from([("NO_PROXY".into(), pattern.into())]);
            assert_eq!(
                proxy_with("https://api.openai.com/", &env, |_| panic!("system lookup")).unwrap(),
                None
            );
        }
        assert!(!no_proxy_matches("openai.com", "notopenai.com"));
    }
    #[test]
    fn websockets_resolve_the_same_full_https_destination_and_respect_wss_override() {
        let target = "wss://api.openai.com/realtime?call_id=test";
        assert_eq!(
            proxy_with(target, &BTreeMap::new(), |url| {
                assert_eq!(url, "https://api.openai.com/realtime?call_id=test");
                Ok(None)
            })
            .unwrap(),
            None
        );
        let env = BTreeMap::from([
            ("WSS_PROXY".into(), "http://ws.test:8080".into()),
            ("HTTPS_PROXY".into(), "http://https.test:8080".into()),
        ]);
        assert_eq!(
            proxy_with(target, &env, |_| panic!("system lookup")).unwrap(),
            Some("http://ws.test:8080".into())
        );
    }
}
