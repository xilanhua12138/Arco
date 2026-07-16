use std::io;
use std::process::{Child, Command, ExitStatus};
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

/// Arrange for a spawned command to lead a fresh process group.
///
/// Every descendant that does not deliberately leave the group can then be
/// terminated together. This matters for script and npm wrappers, where the
/// `Child` held by Arco is not necessarily the long-lived CLI process.
pub fn configure_process_group(command: &mut Command) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;

        // SAFETY: setpgid is async-signal-safe and the closure performs no
        // allocation or other work between fork and exec.
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == -1 {
                    Err(io::Error::last_os_error())
                } else {
                    Ok(())
                }
            });
        }
    }

    #[cfg(not(unix))]
    {
        let _ = command;
    }

    Ok(())
}

/// Terminate the process group led by `child`, escalating from TERM to KILL.
///
/// The group is signalled even if its leader has already exited, so a wrapper
/// cannot leave a detached-in-practice descendant running under the same PGID.
pub fn terminate_process_tree(child: &mut Child, grace: Duration) -> io::Result<ExitStatus> {
    #[cfg(unix)]
    {
        terminate_unix_process_group(child, grace)
    }

    #[cfg(not(unix))]
    {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        let _ = child.kill();
        child.wait()
    }
}

#[cfg(unix)]
fn terminate_unix_process_group(child: &mut Child, grace: Duration) -> io::Result<ExitStatus> {
    let pgid = i32::try_from(child.id())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "child PID does not fit pid_t"))?;
    let mut leader_status = child.try_wait()?;

    signal_group(pgid, libc::SIGTERM)?;
    let deadline = Instant::now() + grace;

    while process_group_exists(pgid)? && Instant::now() < deadline {
        if leader_status.is_none() {
            leader_status = child.wait_timeout(Duration::from_millis(10))?;
        }
        std::thread::sleep(Duration::from_millis(10));
    }

    if process_group_exists(pgid)? {
        signal_group(pgid, libc::SIGKILL)?;
    }

    match leader_status {
        Some(status) => Ok(status),
        None => child.wait(),
    }
}

#[cfg(unix)]
fn signal_group(pgid: i32, signal: i32) -> io::Result<()> {
    // A negative pid addresses the process group whose id is `pgid`.
    let result = unsafe { libc::kill(-pgid, signal) };
    if result == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error)
    }
}

#[cfg(unix)]
fn process_group_exists(pgid: i32) -> io::Result<bool> {
    let result = unsafe { libc::kill(-pgid, 0) };
    if result == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    match error.raw_os_error() {
        Some(libc::ESRCH) => Ok(false),
        // EPERM still proves that a process in the group exists.
        Some(libc::EPERM) => Ok(true),
        _ => Err(error),
    }
}
