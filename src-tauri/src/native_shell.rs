use serde::Deserialize;

pub const NATIVE_SHELL_EVENT: &str = "arco:native-shell";

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NativeShellPage {
    Current,
    History,
    Notes,
    Review,
}

impl NativeShellPage {
    fn as_str(self) -> &'static str {
        match self {
            Self::Current => "current",
            Self::History => "history",
            Self::Notes => "notes",
            Self::Review => "review",
        }
    }
}

#[derive(Debug, Clone, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeShellLabels {
    pub current: String,
    pub history: String,
    pub notes: String,
    pub settings: String,
    pub ready: String,
    pub audio_mode: String,
    pub capture_action: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeShellState {
    pub visible: bool,
    pub page: NativeShellPage,
    pub capture_phase: String,
    pub capture_enabled: bool,
    pub capture_action_visible: bool,
    pub labels: NativeShellLabels,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct NativeShellFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

const NATIVE_SHELL_TAG: isize = 0x4152_5301;
const SHELL_INSET: f64 = 8.0;
const SHELL_WIDTH: f64 = 210.0;

fn native_shell_frame(root_width: f64, root_height: f64) -> Option<NativeShellFrame> {
    if !root_width.is_finite()
        || !root_height.is_finite()
        || root_width < SHELL_WIDTH + SHELL_INSET * 3.0
        || root_height <= SHELL_INSET * 2.0
    {
        return None;
    }
    Some(NativeShellFrame {
        x: SHELL_INSET,
        y: SHELL_INSET,
        width: SHELL_WIDTH,
        height: root_height - SHELL_INSET * 2.0,
    })
}

fn labels_json(labels: &NativeShellLabels) -> Result<String, String> {
    serde_json::to_string(labels)
        .map_err(|error| format!("could not encode native shell labels: {error}"))
}

#[cfg(target_os = "macos")]
mod appkit {
    use super::{labels_json, native_shell_frame, NativeShellState, NATIVE_SHELL_TAG};
    use objc2_app_kit::NSView;
    use objc2_foundation::{NSInteger, NSPoint, NSRect, NSSize};
    use tauri::Manager;

    fn sync_on_main_thread(
        window: &tauri::WebviewWindow,
        state: &NativeShellState,
    ) -> Result<bool, String> {
        let raw_view = window.ns_view().map_err(|error| error.to_string())?;
        // SAFETY: Tauri owns this content view for the WebviewWindow lifetime, and
        // synchronization is dispatched exclusively to AppKit's main thread.
        let root_view = unsafe { &*(raw_view.cast::<NSView>()) };
        let existing = root_view.viewWithTag(NATIVE_SHELL_TAG as NSInteger);

        if !state.visible {
            if let Some(view) = existing {
                view.setHidden(true);
            }
            return Ok(true);
        }

        let root_bounds = root_view.bounds();
        let frame = native_shell_frame(root_bounds.size.width, root_bounds.size.height)
            .ok_or_else(|| "main window is too small for the native shell".to_string())?;
        let frame = NSRect::new(
            NSPoint::new(frame.x, frame.y),
            NSSize::new(frame.width, frame.height),
        );
        let labels = labels_json(&state.labels)?;
        let page = state.page.as_str();

        crate::native_glass::register_app(window.app_handle());
        let updated = existing
            .as_ref()
            .map(|view| {
                crate::native_glass::update_shell_view(
                    view,
                    &labels,
                    page,
                    &state.capture_phase,
                    state.capture_enabled,
                    state.capture_action_visible,
                )
            })
            .transpose()?
            .unwrap_or(false);

        if updated {
            let view = existing.as_ref().expect("updated shell must exist");
            view.setFrame(frame);
            view.setHidden(false);
            return Ok(true);
        }

        if let Some(view) = existing {
            view.removeFromSuperview();
        }
        let view = crate::native_glass::create_shell_view(
            NATIVE_SHELL_TAG,
            &labels,
            page,
            &state.capture_phase,
            state.capture_enabled,
            state.capture_action_visible,
        )?;
        view.setFrame(frame);
        root_view.addSubview(&view);
        view.setHidden(false);
        Ok(true)
    }

    pub fn sync(window: &tauri::WebviewWindow, state: NativeShellState) -> Result<bool, String> {
        let setup_window = window.clone();
        let label = window.label().to_string();
        let (send_result, receive_result) = std::sync::mpsc::sync_channel(1);
        window
            .run_on_main_thread(move || {
                let _ = send_result.send(sync_on_main_thread(&setup_window, &state));
            })
            .map_err(|error| {
                format!("could not dispatch {label} native shell to AppKit: {error}")
            })?;
        receive_result
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|error| {
                format!("timed out while synchronizing {label} native shell: {error}")
            })?
    }
}

#[cfg(target_os = "macos")]
pub fn sync_native_shell(
    window: &tauri::WebviewWindow,
    state: NativeShellState,
) -> Result<bool, String> {
    appkit::sync(window, state)
}

#[cfg(not(target_os = "macos"))]
pub fn sync_native_shell(
    _window: &tauri::WebviewWindow,
    _state: NativeShellState,
) -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::{native_shell_frame, NativeShellFrame, NativeShellPage};

    #[test]
    fn native_shell_reserves_one_fixed_mac_sidebar_and_tracks_window_height() {
        assert_eq!(
            native_shell_frame(1240.0, 820.0),
            Some(NativeShellFrame {
                x: 8.0,
                y: 8.0,
                width: 210.0,
                height: 804.0
            })
        );
        assert_eq!(native_shell_frame(200.0, 820.0), None);
        assert_eq!(native_shell_frame(f64::NAN, 820.0), None);
    }

    #[test]
    fn history_review_keeps_a_distinct_route_for_web_content() {
        assert_eq!(NativeShellPage::History.as_str(), "history");
        assert_eq!(NativeShellPage::Review.as_str(), "review");
    }
}
