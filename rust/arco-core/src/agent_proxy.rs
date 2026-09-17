use std::collections::BTreeMap;
use std::ffi::OsString;
use std::process::Command;

const PROXY_KEYS: &[&str] = &[
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "http_proxy",
    "https_proxy",
    "all_proxy",
    "WS_PROXY",
    "WSS_PROXY",
    "ws_proxy",
    "wss_proxy",
];

/// Finder-launched apps do not inherit shell proxy exports. CLI HTTP clients
/// need the user's existing macOS manual proxy expressed as child environment.
pub(crate) fn configure_agent_proxy(command: &mut Command) {
    #[cfg(target_os = "macos")]
    {
        if PROXY_KEYS.iter().any(|key| std::env::var_os(key).is_some()) {
            return;
        }
        if let Some(settings) = read_system_proxy_settings() {
            apply_proxy_settings(command, &settings, |key| std::env::var_os(key));
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = command;
}

#[cfg(target_os = "macos")]
fn read_system_proxy_settings() -> Option<String> {
    use std::io::Read;
    use std::process::Stdio;
    use std::time::Duration;
    use wait_timeout::ChildExt;

    let mut child = Command::new("/usr/sbin/scutil")
        .arg("--proxy")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    match child.wait_timeout(Duration::from_millis(500)) {
        Ok(Some(status)) if status.success() => {}
        _ => {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
    }
    let mut output = String::new();
    child
        .stdout
        .take()?
        .take(65_537)
        .read_to_string(&mut output)
        .ok()?;
    (output.len() <= 65_536).then_some(output)
}

fn apply_proxy_settings(
    command: &mut Command,
    settings: &str,
    inherited: impl Fn(&str) -> Option<OsString>,
) {
    // Even an explicitly empty proxy is intentional. Do not combine a shell's
    // proxy configuration with a different route from System Settings.
    if PROXY_KEYS.iter().any(|key| inherited(key).is_some()) {
        return;
    }
    for (key, value) in system_proxy_environment(settings) {
        if key == "NO_PROXY" && (inherited("NO_PROXY").is_some() || inherited("no_proxy").is_some())
        {
            continue;
        }
        command.env(key, value);
    }
}

fn system_proxy_environment(settings: &str) -> BTreeMap<String, String> {
    let mut fields = BTreeMap::new();
    let mut exceptions = Vec::new();
    let mut in_exceptions = false;
    let root_depth = usize::from(settings.trim_start().starts_with("<dictionary> {"));
    let mut depth: usize = 0;
    for line in settings.lines().map(str::trim) {
        if line == "}" {
            depth = depth.saturating_sub(1);
            if depth == root_depth {
                in_exceptions = false;
            }
            continue;
        }
        if depth == root_depth && line.starts_with("ExceptionsList : <array>") {
            in_exceptions = true;
        } else if let Some((key, value)) = line.split_once(" : ") {
            if in_exceptions && depth == root_depth + 1 {
                let value = value.strip_prefix('*').unwrap_or(value);
                if !value.is_empty()
                    && value
                        .bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b".-_:/".contains(&b))
                {
                    exceptions.push(value.to_string());
                }
            } else if depth == root_depth {
                // __SCOPED__ / __SUPPLEMENTAL__ entries only apply to specific
                // interfaces or domains; never promote them to global routing.
                fields.insert(key, value);
            }
        }
        if line.ends_with('{') {
            depth += 1;
        }
    }
    let mut environment = BTreeMap::new();
    // A PAC script requires per-URL evaluation; it is not a static proxy URL.
    if fields.get("ProxyAutoConfigEnable") == Some(&"1") {
        return environment;
    }
    for (prefix, variable, scheme) in [
        ("HTTP", "HTTP_PROXY", "http"),
        ("HTTPS", "HTTPS_PROXY", "http"),
        ("SOCKS", "ALL_PROXY", "socks5h"),
    ] {
        if fields.get(format!("{prefix}Enable").as_str()) != Some(&"1") {
            continue;
        }
        let host = fields.get(format!("{prefix}Proxy").as_str());
        let port = fields.get(format!("{prefix}Port").as_str());
        if let (Some(host), Some(port)) = (host, port) {
            if let Some(url) = proxy_url(scheme, host, port) {
                environment.insert(variable.into(), url);
            }
        }
    }
    if !environment.is_empty() && !exceptions.is_empty() {
        environment.insert("NO_PROXY".into(), exceptions.join(","));
    }
    environment
}

fn proxy_url(scheme: &str, host: &str, port: &str) -> Option<String> {
    let port = port.parse::<u16>().ok().filter(|port| *port != 0)?;
    let host = if let Ok(address) = host.trim_matches(['[', ']']).parse::<std::net::Ipv6Addr>() {
        format!("[{address}]")
    } else if !host.is_empty()
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b".-_".contains(&b))
    {
        host.to_string()
    } else {
        return None;
    };
    Some(format!("{scheme}://{host}:{port}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Captured from scutil --proxy on the Mac where the GUI connection timed out.
    const SYSTEM_PROXY: &str = "<dictionary> {\n  ExceptionsList : <array> {\n    0 : localhost\n    1 : 127.0.0.1\n    2 : *.local\n  }\n  HTTPEnable : 1\n  HTTPPort : 7890\n  HTTPProxy : 127.0.0.1\n  HTTPSEnable : 1\n  HTTPSPort : 7890\n  HTTPSProxy : 127.0.0.1\n  SOCKSEnable : 1\n  SOCKSPort : 7890\n  SOCKSProxy : 127.0.0.1\n}";

    #[test]
    fn gui_launch_translates_macos_proxy_for_cli_network_requests() {
        assert_eq!(
            system_proxy_environment(SYSTEM_PROXY),
            BTreeMap::from([
                ("HTTP_PROXY".into(), "http://127.0.0.1:7890".into()),
                ("HTTPS_PROXY".into(), "http://127.0.0.1:7890".into()),
                ("ALL_PROXY".into(), "socks5h://127.0.0.1:7890".into()),
                ("NO_PROXY".into(), "localhost,127.0.0.1,.local".into()),
            ])
        );
    }

    #[test]
    fn disabled_missing_or_invalid_proxy_does_not_change_routing() {
        for settings in [
            "",
            "not a dictionary",
            "HTTPEnable : 0\nHTTPProxy : localhost\nHTTPPort : 7890",
            "HTTPEnable : 1\nHTTPProxy : localhost",
            "HTTPEnable : 1\nHTTPProxy : localhost\nHTTPPort : 0",
            "HTTPEnable : 1\nHTTPProxy : localhost\nHTTPPort : 65536",
            "HTTPEnable : 1\nHTTPProxy : user@host/path\nHTTPPort : 7890",
            "ProxyAutoConfigEnable : 1\nHTTPEnable : 1\nHTTPProxy : localhost\nHTTPPort : 7890",
        ] {
            assert_eq!(
                system_proxy_environment(settings),
                BTreeMap::new(),
                "{settings}"
            );
        }
    }

    #[test]
    fn ipv6_socks_proxy_uses_remote_dns_and_brackets() {
        assert_eq!(
            system_proxy_environment("SOCKSEnable : 1\nSOCKSProxy : ::1\nSOCKSPort : 1080"),
            BTreeMap::from([("ALL_PROXY".into(), "socks5h://[::1]:1080".into())])
        );
    }

    #[test]
    fn interface_specific_proxy_must_not_become_a_global_proxy() {
        let settings = "<dictionary> {\n  HTTPSEnable : 0\n  __SCOPED__ : <dictionary> {\n    en9 : <dictionary> {\n      HTTPSEnable : 1\n      HTTPSProxy : scoped.example.test\n      HTTPSPort : 8080\n    }\n  }\n}";
        assert_eq!(system_proxy_environment(settings), BTreeMap::new());
    }

    #[test]
    fn direct_connection_child_has_no_proxy_variables() {
        let mut command = Command::new("/usr/bin/env");
        command.env_clear();
        apply_proxy_settings(
            &mut command,
            "<dictionary> {\n  HTTPEnable : 0\n  HTTPSEnable : 0\n  SOCKSEnable : 0\n}",
            |_| None,
        );
        assert_eq!(command.get_envs().count(), 0);
        let output = command.output().unwrap();
        assert!(output.status.success());
        assert_eq!(output.stdout, b"");
    }

    #[test]
    fn explicit_shell_proxy_including_empty_value_takes_precedence() {
        for key in PROXY_KEYS {
            for value in ["", "http://proxy.example.test:8080"] {
                let mut command = Command::new("/usr/bin/true");
                apply_proxy_settings(&mut command, SYSTEM_PROXY, |name| {
                    (name == *key).then(|| value.into())
                });
                assert_eq!(
                    command.get_envs().count(),
                    0,
                    "must preserve explicit {key}={value}"
                );
            }
        }
    }

    #[test]
    fn existing_proxy_exceptions_are_preserved() {
        let mut command = Command::new("/usr/bin/true");
        apply_proxy_settings(&mut command, SYSTEM_PROXY, |name| {
            (name == "no_proxy").then(|| "internal.example.test".into())
        });
        let env: BTreeMap<_, _> = command
            .get_envs()
            .map(|(k, v)| (k.to_str().unwrap(), v.unwrap().to_str().unwrap()))
            .collect();
        assert_eq!(
            env,
            BTreeMap::from([
                ("HTTP_PROXY", "http://127.0.0.1:7890"),
                ("HTTPS_PROXY", "http://127.0.0.1:7890"),
                ("ALL_PROXY", "socks5h://127.0.0.1:7890")
            ])
        );
    }

    #[test]
    fn child_process_receives_system_proxy_without_parent_environment_changes() {
        let mut command = Command::new("/bin/sh");
        command.env_clear().args([
            "-c",
            "printf '%s\\n%s\\n%s' \"$HTTPS_PROXY\" \"$ALL_PROXY\" \"$NO_PROXY\"",
        ]);
        apply_proxy_settings(&mut command, SYSTEM_PROXY, |_| None);
        let output = command.output().unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            "http://127.0.0.1:7890\nsocks5h://127.0.0.1:7890\nlocalhost,127.0.0.1,.local"
        );
    }
}
