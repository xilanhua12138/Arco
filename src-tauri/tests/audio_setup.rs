use arco_lib::audio_setup::{analyze_interleaved_pcm, AudioSetupTester};
use arco_lib::models::AudioSetupCheck;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tempfile::TempDir;

fn executable_script(root: &Path, name: &str, body: &str) -> PathBuf {
    let path = root.join(name);
    fs::write(&path, body).unwrap();
    let mut permissions = fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(&path, permissions).unwrap();
    path
}

fn stereo_pcm(system: i16, microphone: i16, frames: usize) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(frames * 4);
    for _ in 0..frames {
        bytes.extend_from_slice(&system.to_le_bytes());
        bytes.extend_from_slice(&microphone.to_le_bytes());
    }
    bytes
}

#[test]
fn pcm_analysis_keeps_system_and_microphone_independent() {
    let result = analyze_interleaved_pcm("both", &stereo_pcm(9_000, 0, 1_600)).unwrap();
    assert!(!result.success);
    assert!(result.system.ready);
    assert!(result.system.level.unwrap() > 0.25);
    assert!(!result.microphone.ready);
    assert_eq!(result.microphone.level, Some(0.0));

    let mic_only = analyze_interleaved_pcm("mic", &stereo_pcm(0, 7_000, 1_600)).unwrap();
    assert!(mic_only.success);
    assert!(!mic_only.system.required);
    assert!(mic_only.microphone.required);
    assert!(mic_only.microphone.ready);
}

#[test]
fn pcm_analysis_rejects_invalid_modes_and_malformed_frames() {
    assert!(analyze_interleaved_pcm("room", &[])
        .unwrap_err()
        .contains("invalid audio mode"));
    assert!(analyze_interleaved_pcm("both", &[1, 2, 3])
        .unwrap_err()
        .contains("stereo PCM"));
}

#[test]
fn tester_reports_missing_recorder_and_native_errors_precisely() {
    let root = TempDir::new().unwrap();
    let missing =
        AudioSetupTester::with_binary(root.path().join("missing"), Duration::from_millis(50));
    assert!(missing.test("both").unwrap_err().contains("not executable"));

    let denied = executable_script(
        root.path(),
        "denied-recorder",
        "#!/bin/sh\necho 'microphone permission denied' >&2\nexit 13\n",
    );
    let error = AudioSetupTester::with_binary(denied, Duration::from_secs(2))
        .test("mic")
        .unwrap_err();
    assert!(error.contains("status 13"));
    assert!(error.contains("microphone permission denied"));
}

#[test]
fn tester_marks_screen_capture_permission_failures_as_restart_required() {
    let root = TempDir::new().unwrap();
    let denied = executable_script(
        root.path(),
        "screen-denied-recorder",
        "#!/bin/sh\necho 'no display is available (check Screen Recording permission)' >&2\nexit 13\n",
    );

    let error = AudioSetupTester::with_binary(denied, Duration::from_secs(2))
        .test("system")
        .unwrap_err();

    assert!(error.starts_with("ARCO_AUDIO_PERMISSION_RESTART_REQUIRED:"));
    assert!(error.contains("Screen Recording permission"));
}

#[test]
fn tester_recognizes_localized_screen_capture_tcc_failures() {
    let root = TempDir::new().unwrap();
    let denied = executable_script(
        root.path(),
        "localized-screen-denied-recorder",
        "#!/bin/sh\necho 'Error Domain=com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3801 用户拒绝了应用程序、窗口、显示器捕捉的TCC' >&2\nexit 1\n",
    );

    let error = AudioSetupTester::with_binary(denied, Duration::from_secs(2))
        .test("system")
        .unwrap_err();

    assert!(error.starts_with("ARCO_AUDIO_PERMISSION_RESTART_REQUIRED:"));
    assert!(error.contains("SCStreamErrorDomain"));
    assert!(error.contains("Code=-3801"));
}

#[test]
fn tester_returns_a_strong_no_signal_result_instead_of_false_success() {
    let root = TempDir::new().unwrap();
    let silent = executable_script(
        root.path(),
        "silent-recorder",
        "#!/bin/sh\nprintf 'ARCO_RECORDER_STARTED: both\\n' >&2\nwhile :; do printf '\\000\\000\\000\\000'; done\n",
    );
    let result: AudioSetupCheck = AudioSetupTester::with_binary(silent, Duration::from_millis(80))
        .test("both")
        .unwrap();
    assert!(!result.success);
    assert!(!result.system.ready);
    assert!(!result.microphone.ready);
}

#[test]
fn tester_does_not_misclassify_an_unstarted_recorder_as_silence() {
    let root = TempDir::new().unwrap();
    let never_started = executable_script(
        root.path(),
        "never-started-recorder",
        "#!/bin/sh\nwhile :; do printf '\\000\\000\\000\\000'; done\n",
    );

    let error = AudioSetupTester::with_timeouts(
        never_started,
        Duration::from_millis(80),
        Duration::from_millis(30),
    )
    .test("system")
    .unwrap_err();

    assert!(
        error.contains("did not start within"),
        "unexpected startup error: {error}"
    );
    assert!(
        !error.contains("no signal"),
        "startup failures must not be reported as silence: {error}"
    );
}

#[test]
fn tester_samples_only_after_the_recorder_start_handshake() {
    let root = TempDir::new().unwrap();
    let delayed = executable_script(
        root.path(),
        "delayed-recorder",
        "#!/bin/sh\nprintf '\\000\\000\\000\\000'\nprintf 'ARCO_RECORDER_STARTED: system\\n' >&2\nwhile :; do printf '\\050\\175\\000\\000'; done\n",
    );

    let result =
        AudioSetupTester::with_timeouts(delayed, Duration::from_secs(2), Duration::from_millis(80))
            .test("system")
            .unwrap();

    assert!(result.success);
    assert!(result.system.ready);
    assert!(result.system.level.unwrap() > 0.9);
    assert!(!result.microphone.required);
}
