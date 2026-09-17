//! Start network workers through the user's login shell, like Dayflow's
//! LoginShellRunner. Proxy selection belongs to the HTTP/WebSocket transport.

#[cfg(target_os = "macos")]
const SHELL_READY: &str = "ARCO_GPT_LIVE_LOGIN_SHELL";

/// Run before creating threads. Both execs preserve PID and pipes so the native
/// app retains cancellation ownership. Arguments are positional, never shell code.
pub fn inherit_login_shell() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::process::CommandExt;
        if std::env::var_os(SHELL_READY).as_deref() == Some(std::ffi::OsStr::new("1")) {
            return Ok(());
        }
        let executable = std::env::current_exe()
            .map_err(|_| "Could not locate the GPT Live worker".to_string())?;
        let mut command = login_shell_command(&executable, std::env::args_os().skip(1));
        let error = command.exec();
        Err(format!(
            "Could not start GPT Live through the login shell: {error}"
        ))
    }
    #[cfg(not(target_os = "macos"))]
    Ok(())
}

#[cfg(target_os = "macos")]
fn login_shell_command(
    executable: &std::path::Path,
    arguments: impl IntoIterator<Item = std::ffi::OsString>,
) -> std::process::Command {
    let mut command = std::process::Command::new(user_login_shell());
    command
        .args(["-l", "-i", "-c", "exec \"$@\"", "arco-gpt-live"])
        .arg(executable)
        .args(arguments)
        .env(SHELL_READY, "1");
    command
}

#[cfg(target_os = "macos")]
fn user_login_shell() -> std::path::PathBuf {
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut buffer = vec![0u8; 65_536];
    let mut result = std::ptr::null_mut();
    unsafe {
        if libc::getpwuid_r(
            libc::getuid(),
            entry.as_mut_ptr(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            &mut result,
        ) == 0
            && !result.is_null()
        {
            let shell = (*result).pw_shell;
            if !shell.is_null() {
                if let Ok(path) = std::ffi::CStr::from_ptr(shell).to_str() {
                    if path.starts_with('/') && std::path::Path::new(path).is_file() {
                        return path.into();
                    }
                }
            }
        }
    }
    "/bin/zsh".into()
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn login_shell_preserves_arguments_and_cannot_execute_path_text() {
        let directory = tempfile::tempdir().unwrap();
        let marker = directory.path().join("should-not-exist");
        let argument = format!("spaces ' quotes \" 中文 $(touch {}) ;", marker.display());
        let output = login_shell_command(
            std::path::Path::new("/usr/bin/printf"),
            ["%s".into(), argument.clone().into()],
        )
        .output()
        .unwrap();
        assert!(output.status.success());
        assert!(String::from_utf8(output.stdout)
            .unwrap()
            .ends_with(&argument));
        assert!(!marker.exists());
    }
}
