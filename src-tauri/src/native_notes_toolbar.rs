use serde::Deserialize;

pub const NATIVE_NOTES_TOOLBAR_EVENT: &str = "arco:native-notes-toolbar";

const NATIVE_NOTES_TOOLBAR_TAG: isize = 0x4152_5401;
const REQUIRED_LABELS: [&str; 18] = [
    "format",
    "title",
    "heading",
    "subheading",
    "body",
    "monostyled",
    "bold",
    "italic",
    "strikethrough",
    "bullet",
    "dash",
    "numbered",
    "checklist",
    "quote",
    "table",
    "code",
    "write",
    "preview",
];

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NativeNotesToolbarMode {
    Write,
    Preview,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeNotesToolbarState {
    pub x: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
    pub viewport_height: f64,
    pub visible: bool,
    pub obscured: bool,
    pub mode: NativeNotesToolbarMode,
    pub labels_json: String,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AppKitNotesToolbarFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn notes_toolbar_mode(mode: NativeNotesToolbarMode) -> i32 {
    match mode {
        NativeNotesToolbarMode::Write => 0,
        NativeNotesToolbarMode::Preview => 1,
    }
}

fn labels_are_valid(labels_json: &str) -> bool {
    let Ok(serde_json::Value::Object(labels)) = serde_json::from_str(labels_json) else {
        return false;
    };
    REQUIRED_LABELS
        .iter()
        .all(|key| labels.get(*key).is_some_and(serde_json::Value::is_string))
}

fn appkit_notes_toolbar_frame(state: &NativeNotesToolbarState) -> Option<AppKitNotesToolbarFrame> {
    let geometry = [
        state.x,
        state.top,
        state.width,
        state.height,
        state.viewport_height,
    ];
    if !state.visible
        || geometry.iter().any(|value| !value.is_finite())
        || state.width <= 0.0
        || state.height <= 0.0
        || state.viewport_height <= 0.0
        || !labels_are_valid(&state.labels_json)
    {
        return None;
    }
    let y = state.viewport_height - state.top - state.height;
    y.is_finite().then_some(AppKitNotesToolbarFrame {
        x: state.x,
        y,
        width: state.width,
        height: state.height,
    })
}

#[cfg(target_os = "macos")]
mod appkit {
    use super::{
        appkit_notes_toolbar_frame, notes_toolbar_mode, NativeNotesToolbarState,
        NATIVE_NOTES_TOOLBAR_TAG,
    };
    use objc2::MainThreadMarker;
    use objc2_app_kit::NSView;
    use objc2_foundation::{NSInteger, NSPoint, NSRect, NSSize};
    use tauri::Manager;

    fn sync_on_main_thread(
        window: &tauri::WebviewWindow,
        state: &NativeNotesToolbarState,
    ) -> Result<bool, String> {
        MainThreadMarker::new().ok_or_else(|| {
            "native notes toolbar synchronization did not run on the main thread".to_string()
        })?;
        let raw_view = window.ns_view().map_err(|error| error.to_string())?;
        // SAFETY: Tauri owns the WebView for the window lifetime, and this code
        // runs only on AppKit's main thread.
        let root_view = unsafe { &*(raw_view.cast::<NSView>()) };
        let existing = root_view.viewWithTag(NATIVE_NOTES_TOOLBAR_TAG as NSInteger);

        let Some(frame) = appkit_notes_toolbar_frame(state) else {
            if let Some(view) = existing {
                // The toolbar left the document hierarchy entirely. Modal coverage
                // remains mounted and is handled by SwiftUI's native inactive state.
                view.removeFromSuperview();
            }
            return Ok(true);
        };
        let frame = NSRect::new(
            NSPoint::new(frame.x, frame.y),
            NSSize::new(frame.width, frame.height),
        );
        crate::native_glass::register_app(window.app_handle());
        let mode = notes_toolbar_mode(state.mode);
        let updated = existing
            .as_ref()
            .map(|view| {
                crate::native_glass::update_notes_toolbar_view(
                    view,
                    &state.labels_json,
                    mode,
                    state.obscured,
                )
            })
            .transpose()?
            .unwrap_or(false);

        if updated {
            let view = existing.as_ref().expect("updated toolbar must exist");
            view.setFrame(frame);
            view.setHidden(false);
        } else {
            if let Some(view) = existing.as_ref() {
                view.removeFromSuperview();
            }
            let view = crate::native_glass::create_notes_toolbar_view(
                NATIVE_NOTES_TOOLBAR_TAG,
                &state.labels_json,
                mode,
                state.obscured,
            )?;
            view.setFrame(frame);
            root_view.addSubview(&view);
            view.setHidden(false);
        }
        Ok(true)
    }

    pub fn sync(
        window: &tauri::WebviewWindow,
        state: NativeNotesToolbarState,
    ) -> Result<bool, String> {
        let setup_window = window.clone();
        let label = window.label().to_string();
        let (send_result, receive_result) = std::sync::mpsc::sync_channel(1);
        window
            .run_on_main_thread(move || {
                let _ = send_result.send(sync_on_main_thread(&setup_window, &state));
            })
            .map_err(|error| {
                format!("could not dispatch {label} native notes toolbar to AppKit: {error}")
            })?;
        receive_result
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|error| {
                format!("timed out while synchronizing {label} native notes toolbar: {error}")
            })?
    }
}

#[cfg(target_os = "macos")]
pub fn sync_native_notes_toolbar(
    window: &tauri::WebviewWindow,
    state: NativeNotesToolbarState,
) -> Result<bool, String> {
    appkit::sync(window, state)
}

#[cfg(not(target_os = "macos"))]
pub fn sync_native_notes_toolbar(
    _window: &tauri::WebviewWindow,
    _state: NativeNotesToolbarState,
) -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::{
        appkit_notes_toolbar_frame, labels_are_valid, NativeNotesToolbarMode,
        NativeNotesToolbarState,
    };

    fn labels() -> String {
        serde_json::json!({
            "format": "Format", "title": "Title", "heading": "Heading", "subheading": "Subheading",
            "body": "Body", "monostyled": "Monostyled", "bold": "Bold", "italic": "Italic",
            "strikethrough": "Strikethrough",
            "bullet": "Bullets", "dash": "Dashes", "numbered": "Numbers", "checklist": "Checklist",
            "quote": "Quote", "table": "Table", "code": "Code",
            "write": "Write", "preview": "Preview"
        })
        .to_string()
    }

    fn state() -> NativeNotesToolbarState {
        NativeNotesToolbarState {
            x: 430.0,
            top: 48.0,
            width: 390.0,
            height: 44.0,
            viewport_height: 760.0,
            visible: true,
            obscured: false,
            mode: NativeNotesToolbarMode::Write,
            labels_json: labels(),
        }
    }

    #[test]
    fn converts_web_geometry_to_the_native_toolbar_frame() {
        let frame = appkit_notes_toolbar_frame(&state()).expect("valid toolbar has a frame");
        assert_eq!(frame.x, 430.0);
        assert_eq!(frame.y, 668.0);
        assert_eq!(frame.width, 390.0);
        assert_eq!(frame.height, 44.0);
    }

    #[test]
    fn rejects_hidden_invalid_or_unlocalized_toolbars() {
        let mut hidden = state();
        hidden.visible = false;
        assert_eq!(appkit_notes_toolbar_frame(&hidden), None);

        let mut invalid = state();
        invalid.width = f64::NAN;
        assert_eq!(appkit_notes_toolbar_frame(&invalid), None);

        let mut missing_label = state();
        missing_label.labels_json = "{\"format\":\"Format\"}".to_string();
        assert_eq!(appkit_notes_toolbar_frame(&missing_label), None);
        assert!(!labels_are_valid("not-json"));
    }
}
