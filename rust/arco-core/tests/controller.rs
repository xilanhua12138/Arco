use arco_core::controller::{Controller, EventSink};
use arco_core::paths::AppPaths;
use serde_json::json;
use std::fs;
use std::sync::{Arc, Mutex};
use tempfile::TempDir;

#[derive(Default)]
struct RecordingEvents(Mutex<Vec<(String, serde_json::Value)>>);

impl EventSink for RecordingEvents {
    fn emit(&self, name: &str, payload: serde_json::Value) {
        self.0.lock().unwrap().push((name.to_string(), payload));
    }
}

fn paths(root: &TempDir) -> AppPaths {
    let home = root.path().join("home");
    let app_data = home.join("Library/Application Support/Arco");
    AppPaths {
        transcripts: app_data.join("transcripts"),
        notes: app_data.join("notes"),
        legacy_transcripts: home.join(".claude/meeting-transcripts"),
        native_dir: root.path().join("native"),
        home,
        app_data,
    }
}

#[test]
fn controller_exposes_the_existing_command_contract_without_a_ui_framework() {
    let root = TempDir::new().unwrap();
    let events = Arc::new(RecordingEvents::default());
    let controller = Controller::new(paths(&root), events).unwrap();

    let capture = controller.dispatch("capture_status", json!({})).unwrap();
    assert_eq!(capture["phase"], "idle");
    assert_eq!(capture["activeMeetingId"], serde_json::Value::Null);

    let meetings = controller
        .dispatch("list_meetings", json!({ "query": "" }))
        .unwrap();
    assert_eq!(meetings, json!([]));

    let error = controller.dispatch("not_a_command", json!({})).unwrap_err();
    assert_eq!(error, "unknown backend command: not_a_command");
}

#[test]
fn directory_mutations_keep_payload_and_event_names_stable() {
    let root = TempDir::new().unwrap();
    let events = Arc::new(RecordingEvents::default());
    let controller = Controller::new(paths(&root), events.clone()).unwrap();
    let custom = root.path().join("meeting-notes");
    fs::create_dir_all(&custom).unwrap();

    let result = controller
        .dispatch(
            "set_notes_directory",
            json!({ "directory": custom.to_string_lossy() }),
        )
        .unwrap();

    assert_eq!(result["usingDefault"], false);
    assert_eq!(
        result["selectedDirectory"],
        custom.canonicalize().unwrap().to_string_lossy().as_ref()
    );
    let recorded = events.0.lock().unwrap();
    assert_eq!(recorded.len(), 1);
    assert_eq!(recorded[0].0, "arco:notes-storage-changed");
    assert_eq!(recorded[0].1, result);
}
