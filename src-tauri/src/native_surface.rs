use serde::Deserialize;

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NativeGlassSurfaceTone {
    Neutral,
    Accent,
    Elevated,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeGlassSurfaceState {
    pub id: String,
    pub x: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
    pub viewport_height: f64,
    pub visible: bool,
    pub obscured: bool,
    pub corner_radius: f64,
    pub tone: NativeGlassSurfaceTone,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AppKitSurfaceFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn native_surface_tag(id: &str) -> Option<isize> {
    match id {
        "sidebar-capture" => Some(0x4152_5301),
        "current-stats" => Some(0x4152_5302),
        "current-shortcuts" => Some(0x4152_5303),
        _ => None,
    }
}

fn surface_tone(tone: NativeGlassSurfaceTone) -> i32 {
    match tone {
        NativeGlassSurfaceTone::Neutral => 0,
        NativeGlassSurfaceTone::Accent => 1,
        NativeGlassSurfaceTone::Elevated => 2,
    }
}

fn appkit_surface_frame(state: &NativeGlassSurfaceState) -> Option<AppKitSurfaceFrame> {
    let geometry = [
        state.x,
        state.top,
        state.width,
        state.height,
        state.viewport_height,
        state.corner_radius,
    ];
    if !state.visible
        || native_surface_tag(&state.id).is_none()
        || geometry.iter().any(|value| !value.is_finite())
        || state.width <= 0.0
        || state.height <= 0.0
        || state.viewport_height <= 0.0
        || state.corner_radius < 0.0
    {
        return None;
    }

    let y = state.viewport_height - state.top - state.height;
    y.is_finite().then_some(AppKitSurfaceFrame {
        x: state.x,
        y,
        width: state.width,
        height: state.height,
    })
}

#[cfg(target_os = "macos")]
mod appkit {
    use super::{appkit_surface_frame, native_surface_tag, surface_tone, NativeGlassSurfaceState};
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSView, NSWindowOrderingMode};
    use objc2_foundation::{NSInteger, NSPoint, NSRect, NSSize};
    const BASE_WINDOW_GLASS_TAG: NSInteger = 96_945_937;

    fn sync_on_main_thread(
        window: &tauri::WebviewWindow,
        state: &NativeGlassSurfaceState,
    ) -> Result<bool, String> {
        MainThreadMarker::new().ok_or_else(|| {
            "native glass surface synchronization did not run on the main thread".to_string()
        })?;
        let tag = native_surface_tag(&state.id)
            .ok_or_else(|| format!("{} is not an approved native glass surface", state.id))?
            as NSInteger;
        let raw_view = window.ns_view().map_err(|error| error.to_string())?;
        // SAFETY: Tauri owns this NSView for the WebviewWindow lifetime, and this
        // function is dispatched to AppKit's main thread before dereferencing it.
        let root_view = unsafe { &*(raw_view.cast::<NSView>()) };
        let existing = root_view.viewWithTag(tag);

        let Some(frame) = appkit_surface_frame(state) else {
            if let Some(view) = existing {
                view.setHidden(true);
            }
            return Ok(true);
        };
        let frame = NSRect::new(
            NSPoint::new(frame.x, frame.y),
            NSSize::new(frame.width, frame.height),
        );
        let tone = surface_tone(state.tone);
        let updated = existing.as_ref().is_some_and(|view| {
            crate::native_glass::update_surface_view(
                view,
                state.corner_radius,
                tone,
                false,
                state.obscured,
            )
        });

        if updated {
            let view = existing.as_ref().expect("updated view must exist");
            view.setFrame(frame);
            view.setHidden(false);
        } else {
            if let Some(view) = existing.as_ref() {
                view.removeFromSuperview();
            }
            let view = crate::native_glass::create_surface_view(
                tag,
                state.corner_radius,
                tone,
                false,
                state.obscured,
            )?;
            view.setFrame(frame);
            if let Some(base_glass) = root_view.viewWithTag(BASE_WINDOW_GLASS_TAG) {
                root_view.addSubview_positioned_relativeTo(
                    &view,
                    NSWindowOrderingMode::Above,
                    Some(&base_glass),
                );
            } else {
                root_view.addSubview_positioned_relativeTo(
                    &view,
                    NSWindowOrderingMode::Below,
                    None,
                );
            }
            view.setHidden(false);
        }

        Ok(true)
    }

    pub fn sync(
        window: &tauri::WebviewWindow,
        state: NativeGlassSurfaceState,
    ) -> Result<bool, String> {
        let setup_window = window.clone();
        let label = window.label().to_string();
        let (send_result, receive_result) = std::sync::mpsc::sync_channel(1);
        window
            .run_on_main_thread(move || {
                let _ = send_result.send(sync_on_main_thread(&setup_window, &state));
            })
            .map_err(|error| {
                format!("could not dispatch {label} native glass surface to AppKit: {error}")
            })?;
        receive_result
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|error| {
                format!("timed out while synchronizing {label} native glass surface: {error}")
            })?
    }
}

#[cfg(target_os = "macos")]
pub fn sync_native_glass_surface(
    window: &tauri::WebviewWindow,
    state: NativeGlassSurfaceState,
) -> Result<bool, String> {
    appkit::sync(window, state)
}

#[cfg(not(target_os = "macos"))]
pub fn sync_native_glass_surface(
    _window: &tauri::WebviewWindow,
    _state: NativeGlassSurfaceState,
) -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::{
        appkit_surface_frame, native_surface_tag, NativeGlassSurfaceState, NativeGlassSurfaceTone,
    };

    fn state() -> NativeGlassSurfaceState {
        NativeGlassSurfaceState {
            id: "current-stats".to_string(),
            x: 280.0,
            top: 420.0,
            width: 520.0,
            height: 160.0,
            viewport_height: 760.0,
            visible: true,
            obscured: false,
            corner_radius: 18.0,
            tone: NativeGlassSurfaceTone::Neutral,
        }
    }

    #[test]
    fn only_matrix_style_functional_dashboard_surfaces_receive_native_glass() {
        assert_ne!(native_surface_tag("sidebar-capture"), None);
        assert_ne!(native_surface_tag("current-stats"), None);
        assert_ne!(native_surface_tag("current-shortcuts"), None);
        assert_eq!(native_surface_tag("notes-document"), None);
        assert_eq!(native_surface_tag("history-list"), None);
        assert_eq!(native_surface_tag("navigation-row"), None);
    }

    #[test]
    fn native_surface_geometry_uses_appkit_coordinates() {
        let frame = appkit_surface_frame(&state()).expect("valid surface should have a frame");
        assert_eq!(frame.x, 280.0);
        assert_eq!(frame.y, 180.0);
        assert_eq!(frame.width, 520.0);
        assert_eq!(frame.height, 160.0);
    }

    #[test]
    fn hidden_unknown_and_invalid_surfaces_are_rejected() {
        let mut hidden = state();
        hidden.visible = false;
        assert_eq!(appkit_surface_frame(&hidden), None);

        let mut unknown = state();
        unknown.id = "notes-document".to_string();
        assert_eq!(appkit_surface_frame(&unknown), None);

        let mut invalid = state();
        invalid.corner_radius = f64::NAN;
        assert_eq!(appkit_surface_frame(&invalid), None);
    }
}
