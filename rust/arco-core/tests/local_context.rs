use arco_core::{agent::AgentRunner, meetings::parse_meeting};
use std::{fs, os::unix::fs::PermissionsExt, time::Duration};

#[test]
fn local_codex_keeps_configuration_and_writes_outside_the_starting_directory() {
    let root = tempfile::tempdir().unwrap();
    let project = root.path().join("project");
    let sibling = root.path().join("other-project");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(&sibling).unwrap();
    fs::write(sibling.join("AGENTS.md"), "outside-instructions").unwrap();
    let fake = project.join("codex-probe");
    fs::write(&fake, r#"#!/bin/sh
input=$(cat)
case "$*" in *"danger-full-access"*) full=yes ;; *) full=no ;; esac
case "$*" in *"--ignore-user-config"*|*"inherit=none"*) config=isolated ;; *) config=normal ;; esac
case "$*" in *"developer_instructions="*) instructions=developer ;; *) instructions=missing ;; esac
outside=$(/bin/cat ../other-project/AGENTS.md)
printf changed > ../other-project/result.txt
printf '{"type":"thread.started","thread_id":"019f4b00-9999-7000-8000-000000000009"}\n'
printf '{"type":"item.completed","item":{"id":"local","type":"agent_message","text":"full=%s config=%s instructions=%s outside=%s"}}\n' "$full" "$config" "$instructions" "$outside"
"#).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
    let transcript = project.join("meeting.md");
    fs::write(&transcript, "# Meeting\n").unwrap();
    let meeting = parse_meeting(&transcript, "local", None).unwrap();
    let runner = AgentRunner::with_binary("codex", fake, Duration::from_secs(5));
    let reply = runner.run("codex", "read and update the other project", &meeting, "personal", Some(&project)).unwrap();
    assert_eq!(reply.answer, "full=yes config=normal instructions=developer outside=outside-instructions");
    assert_eq!(fs::read_to_string(sibling.join("result.txt")).unwrap(), "changed");
}

#[test]
fn local_claude_has_normal_tools_and_a_system_prompt() {
    let root = tempfile::tempdir().unwrap();
    let fake = root.path().join("claude-probe");
    fs::write(&fake, r#"#!/bin/sh
cat >/dev/null
case "$*" in *"--tools default"*) tools=normal ;; *) tools=limited ;; esac
case "$*" in *"--safe-mode"*) config=isolated ;; *) config=normal ;; esac
system=no
while [ "$#" -gt 0 ]; do
  if [ "$1" = --append-system-prompt-file ]; then
    shift
    if /usr/bin/grep -q 'read and edit files in other directories' "$1"; then system=yes; fi
  fi
  shift
done
printf '{"type":"result","session_id":"019f4b00-9999-7000-8000-000000000009","result":"tools=%s config=%s system=%s"}\n' "$tools" "$config" "$system"
"#).unwrap();
    fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
    let transcript = root.path().join("meeting.md");
    fs::write(&transcript, "# Meeting\n").unwrap();
    let meeting = parse_meeting(&transcript, "local", None).unwrap();
    let reply = AgentRunner::with_binary("claude", fake, Duration::from_secs(5))
        .run("claude", "inspect my project", &meeting, "personal", Some(root.path())).unwrap();
    assert_eq!(reply.answer, "tools=normal config=normal system=yes");
}
