use arco_core::{
    audio_archive::AudioArchiveStorage, meeting_state::MeetingStateStore, meetings::MeetingStore,
};
use arco_core::{
    controller::{Controller, NoopEventSink},
    paths::AppPaths,
};
use serde_json::{json, Value};
use std::{fs, sync::Arc};
use tempfile::TempDir;

const ID: &str = "local:meeting-20260916-120000.md";
const FILE: &str = "meeting-20260916-120000.md";

fn fixture() -> (TempDir, AppPaths, Controller) {
    let temp = TempDir::new().unwrap();
    let app = temp.path().join("app");
    let paths = AppPaths {
        home: temp.path().to_path_buf(),
        app_data: app.clone(),
        transcripts: app.join("transcripts"),
        notes: app.join("notes"),
        legacy_transcripts: temp.path().join("legacy"),
        native_dir: temp.path().join("native"),
    };
    let controller = Controller::new(paths.clone(), Arc::new(NoopEventSink)).unwrap();
    fs::write(
        paths.transcripts.join(FILE),
        "# Meeting Transcript\n\n**[12:00:01] Local 1:** Archive fixture evidence.\n",
    )
    .unwrap();
    (temp, paths, controller)
}

#[test]
fn archive_is_persistent_searchable_after_restore_and_preserves_content() {
    let (_temp, paths, controller) = fixture();
    let transcript = fs::read(paths.transcripts.join(FILE)).unwrap();
    controller
        .dispatch(
            "rename_meeting",
            json!({"meetingId": ID, "title": "My meeting"}),
        )
        .unwrap();
    assert_eq!(
        controller
            .dispatch("list_meetings", json!({"query":"fixture"}))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
    controller
        .dispatch("set_meeting_archived", json!({"id":ID,"archived":true}))
        .unwrap();
    assert_eq!(
        controller
            .dispatch("list_meetings", json!({"query":"fixture"}))
            .unwrap(),
        json!([])
    );
    let archived = controller
        .dispatch("list_archived_meetings", json!({}))
        .unwrap();
    assert_eq!(archived[0]["title"], "My meeting");
    assert_eq!(fs::read(paths.transcripts.join(FILE)).unwrap(), transcript);
    drop(controller);
    let reopened = Controller::new(paths.clone(), Arc::new(NoopEventSink)).unwrap();
    assert_eq!(
        reopened.dispatch("list_meetings", json!({})).unwrap(),
        json!([])
    );
    reopened
        .dispatch("set_meeting_archived", json!({"id":ID,"archived":false}))
        .unwrap();
    assert_eq!(
        reopened
            .dispatch("list_archived_meetings", json!({}))
            .unwrap(),
        json!([])
    );
    assert_eq!(
        reopened
            .dispatch("list_meetings", json!({"query":"My meeting"}))
            .unwrap()[0]["id"],
        ID
    );
}

#[test]
fn invalid_and_missing_ids_cannot_mutate_storage() {
    let (_temp, paths, controller) = fixture();
    for id in [
        "local:../secret.md",
        "local:/tmp/secret.md",
        "unknown:meeting-20260916-120000.md",
        "local:meeting-missing.md",
    ] {
        assert!(controller
            .dispatch("set_meeting_archived", json!({"id":id,"archived":true}))
            .is_err());
        assert!(controller
            .dispatch("delete_meeting", json!({"id":id}))
            .is_err());
    }
    assert!(paths.transcripts.join(FILE).exists());
    assert!(!paths.app_data.join("meeting-state").exists());
}

#[test]
fn active_transcripts_and_symlink_targets_cannot_be_deleted() {
    let (_temp, paths, _controller) = fixture();
    let store = MeetingStore::new(paths.transcripts.clone(), paths.legacy_transcripts.clone());
    assert!(store
        .deletion_paths(ID, Some(&paths.transcripts.join(FILE)))
        .is_err());
    let linked = paths.transcripts.join("meeting-20260916-130000.md");
    std::os::unix::fs::symlink(paths.transcripts.join(FILE), &linked).unwrap();
    assert!(store
        .deletion_paths("local:meeting-20260916-130000.md", None)
        .is_err());
}

#[test]
fn archive_updates_preserve_titles_and_attachments() {
    let (_temp, paths, _controller) = fixture();
    let state = MeetingStateStore::new(paths.app_data.join("meeting-state"));
    state.set_manual_title(ID, Some("Keep title")).unwrap();
    state
        .add_attachment(ID, "reference.txt", "Keep reference")
        .unwrap();
    state.set_archived(ID, true).unwrap();
    state.set_manual_title(ID, Some("New title")).unwrap();
    assert!(state.archived(ID).unwrap());
    assert_eq!(state.list_attachments(ID).unwrap().len(), 1);
    state.set_archived(ID, false).unwrap();
    assert_eq!(
        state.list_attachments(ID).unwrap()[0].text,
        "Keep reference"
    );
}

#[test]
fn recording_deletion_only_selects_matching_owned_real_directories() {
    let (_temp, paths, _controller) = fixture();
    let store = MeetingStore::new(paths.transcripts.clone(), paths.legacy_transcripts.clone());
    let summary = store.read(ID, None).unwrap().summary;
    let root = paths.home.join("Music/Arco/Recordings");
    for (name, owner, transcript) in [
        ("match", "app.arco.audio-archive", summary.path.as_str()),
        (
            "other-meeting",
            "app.arco.audio-archive",
            "/other/transcript.md",
        ),
        ("foreign", "other.app", summary.path.as_str()),
    ] {
        let dir = root.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("recording.json"),
            json!({"owner":owner,"meetingID":ID,"transcript":transcript}).to_string(),
        )
        .unwrap();
    }
    std::os::unix::fs::symlink(root.join("match"), root.join("linked")).unwrap();
    let audio = AudioArchiveStorage::new(paths.app_data.clone(), &paths.home);
    assert_eq!(
        audio.deletion_paths(&summary).unwrap(),
        vec![root.join("match")]
    );
}

#[test]
#[cfg(target_os = "macos")]
fn delete_moves_only_fixture_meeting_files_and_keeps_separately_saved_notes() {
    let (_temp, paths, controller) = fixture();
    let state = MeetingStateStore::new(paths.app_data.join("meeting-state"));
    state.set_archived(ID, true).unwrap();
    let sidecar = state.deletion_path(ID).unwrap().unwrap();
    let note = paths.notes.join("keep.md");
    fs::write(&note, "saved note").unwrap();
    let transcript = paths.transcripts.join(FILE);
    let live = arco_core::meetings::live_transcript_path(&transcript);
    let timing = transcript.with_extension("md.timing.json");
    fs::write(&live, "{}").unwrap();
    fs::write(&timing, "{}\n").unwrap();
    let audio = paths
        .home
        .join("Music/Arco/Recordings/archive-management-test");
    fs::create_dir_all(&audio).unwrap();
    fs::write(
        audio.join("recording.json"),
        json!({"owner":"app.arco.audio-archive","transcript":transcript}).to_string(),
    )
    .unwrap();
    fs::write(audio.join("audio-000001.m4a"), "fixture").unwrap();
    let other = paths.transcripts.join("meeting-20260916-130000.md");
    fs::copy(&transcript, &other).unwrap();
    assert_eq!(
        controller
            .dispatch("delete_meeting", json!({"id":ID}))
            .unwrap(),
        Value::Null
    );
    for path in [transcript, live, timing, sidecar, audio] {
        assert!(!path.exists(), "{}", path.display());
    }
    assert_eq!(fs::read_to_string(note).unwrap(), "saved note");
    assert!(other.exists());
    assert_eq!(
        controller
            .dispatch("list_archived_meetings", json!({}))
            .unwrap(),
        json!([])
    );
    assert_eq!(
        controller
            .dispatch("list_meetings", json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
