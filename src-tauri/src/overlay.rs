use tauri::{
    AppHandle, LogicalSize, Manager, Monitor, PhysicalPosition, WebviewUrl, WebviewWindow,
    WebviewWindowBuilder,
};

use crate::material;

pub const HUD_LABEL: &str = "recording-hud";
pub const AGENT_LABEL: &str = "agent-overlay";
pub const HUD_SIZE: (f64, f64) = (368.0, 56.0);
pub const AGENT_SIZE: (f64, f64) = (720.0, 560.0);
pub const AGENT_COLLAPSED_SIZE: (f64, f64) = (432.0, 560.0);
const HUD_BOTTOM_MARGIN: f64 = 24.0;
const AGENT_TOP_MARGIN: f64 = 20.0;
const AGENT_RIGHT_MARGIN: f64 = 20.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MonitorGeometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale_factor: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SurfacePosition {
    pub x: i32,
    pub y: i32,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SurfaceFrame {
    pub x: i32,
    pub y: i32,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AgentLayout {
    PlaceDefault,
    PreservePosition,
}

fn physical_size(logical: (f64, f64), scale_factor: f64) -> (i64, i64) {
    (
        (logical.0 * scale_factor).round() as i64,
        (logical.1 * scale_factor).round() as i64,
    )
}

fn logical_size_from_physical(physical: (u32, u32), scale_factor: f64) -> (f64, f64) {
    let scale_factor = if scale_factor.is_finite() && scale_factor > 0.0 {
        scale_factor
    } else {
        1.0
    };
    (
        f64::from(physical.0) / scale_factor,
        f64::from(physical.1) / scale_factor,
    )
}

pub fn hud_position(monitor: MonitorGeometry) -> SurfacePosition {
    let (window_width, window_height) = physical_size(HUD_SIZE, monitor.scale_factor);
    let area_width = i64::from(monitor.width);
    let area_height = i64::from(monitor.height);
    let margin = (HUD_BOTTOM_MARGIN * monitor.scale_factor).round() as i64;
    let x_offset = ((area_width - window_width) / 2).max(0);
    let y_offset = (area_height - window_height - margin).max(0);

    SurfacePosition {
        x: (i64::from(monitor.x) + x_offset) as i32,
        y: (i64::from(monitor.y) + y_offset) as i32,
    }
}

fn agent_position_for_size(monitor: MonitorGeometry, logical_size: (f64, f64)) -> SurfacePosition {
    let (window_width, _) = physical_size(logical_size, monitor.scale_factor);
    let area_width = i64::from(monitor.width);
    let right_margin = (AGENT_RIGHT_MARGIN * monitor.scale_factor).round() as i64;
    let top_margin = (AGENT_TOP_MARGIN * monitor.scale_factor).round() as i64;
    let x_offset = (area_width - window_width - right_margin).max(0);

    SurfacePosition {
        x: (i64::from(monitor.x) + x_offset) as i32,
        y: (i64::from(monitor.y) + top_margin) as i32,
    }
}

fn fitted_agent_size(monitor: MonitorGeometry, requested: (f64, f64)) -> (f64, f64) {
    let scale = monitor.scale_factor.max(1.0);
    let available_width = (f64::from(monitor.width) / scale - AGENT_RIGHT_MARGIN * 2.0).max(1.0);
    // Leave the bottom-centred HUD plus a quiet 20px gap unobscured.
    let available_height = (f64::from(monitor.height) / scale
        - AGENT_TOP_MARGIN
        - HUD_SIZE.1
        - HUD_BOTTOM_MARGIN
        - 20.0)
        .max(1.0);
    (
        requested.0.min(available_width),
        requested.1.min(available_height),
    )
}

pub fn agent_frame(monitor: MonitorGeometry, requested: (f64, f64)) -> SurfaceFrame {
    let fitted = fitted_agent_size(monitor, requested);
    let position = agent_position_for_size(monitor, fitted);
    SurfaceFrame {
        x: position.x,
        y: position.y,
        width: fitted.0,
        height: fitted.1,
    }
}

fn geometry(monitor: &Monitor) -> MonitorGeometry {
    let area = monitor.work_area();
    MonitorGeometry {
        x: area.position.x,
        y: area.position.y,
        width: area.size.width,
        height: area.size.height,
        scale_factor: monitor.scale_factor(),
    }
}

fn monitor_fallback_labels(surface_label: &str) -> [&str; 2] {
    ["main", surface_label]
}

fn preferred_monitor(app: &AppHandle, surface_label: &str) -> Result<Monitor, String> {
    if let Ok(cursor) = app.cursor_position() {
        if let Ok(Some(monitor)) = app.monitor_from_point(cursor.x, cursor.y) {
            return Ok(monitor);
        }
    }

    for label in monitor_fallback_labels(surface_label) {
        if let Some(window) = app.get_webview_window(label) {
            if let Some(monitor) = window
                .current_monitor()
                .map_err(|error| error.to_string())?
            {
                return Ok(monitor);
            }
        }
    }

    let surface = app
        .get_webview_window(surface_label)
        .ok_or_else(|| format!("Arco could not find its {surface_label} window"))?;
    surface
        .primary_monitor()
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "Arco could not find an available display".to_string())
}

fn set_surface_position(
    app: &AppHandle,
    label: &str,
    position: fn(MonitorGeometry) -> SurfacePosition,
) -> Result<WebviewWindow, String> {
    let window = app
        .get_webview_window(label)
        .ok_or_else(|| format!("Arco could not find its {label} window"))?;
    let monitor = preferred_monitor(app, label)?;
    let point = position(geometry(&monitor));
    window
        .set_position(PhysicalPosition::new(point.x, point.y))
        .map_err(|error| error.to_string())?;
    Ok(window)
}

pub fn show_hud(app: &AppHandle) -> Result<(), String> {
    ensure_hud_window(app)?;
    let hud = set_surface_position(app, HUD_LABEL, hud_position)?;
    hud.show().map_err(|error| error.to_string())
}

fn capture_surface_labels() -> [&'static str; 2] {
    [HUD_LABEL, AGENT_LABEL]
}

pub fn release_capture_surfaces(app: &AppHandle) -> Result<(), String> {
    let mut errors = Vec::new();
    for label in capture_surface_labels() {
        if let Some(window) = app.get_webview_window(label) {
            // WebKit can retain the native NSWindow backing a destroyed
            // transparent webview until the app exits. Recreating the HUD on
            // every recording therefore accumulates protected Liquid Glass
            // windows in WindowServer. Hide and reuse the owned surfaces so a
            // long-running Arco process always has at most one of each.
            if let Err(error) = window.hide() {
                errors.push(format!("{label}: {error}"));
            }
        }
    }

    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors.join("; "))
    }
}

fn agent_visibility_after_toggle(currently_visible: bool) -> bool {
    !currently_visible
}

fn agent_layout_for_show(window_existed: bool) -> AgentLayout {
    if window_existed {
        AgentLayout::PreservePosition
    } else {
        AgentLayout::PlaceDefault
    }
}

fn agent_layout_for_transcript_change(window_visible: bool) -> Option<AgentLayout> {
    window_visible.then_some(AgentLayout::PreservePosition)
}

pub fn toggle_agent(app: &AppHandle) -> Result<bool, String> {
    let existing_agent = app.get_webview_window(AGENT_LABEL);
    let currently_visible = existing_agent
        .as_ref()
        .map(|agent| agent.is_visible().map_err(|error| error.to_string()))
        .transpose()?
        .unwrap_or(false);

    if !agent_visibility_after_toggle(currently_visible) {
        hide_agent(app)?;
        return Ok(false);
    }

    let layout = agent_layout_for_show(existing_agent.is_some());
    let agent = match existing_agent {
        Some(agent) => agent,
        None => ensure_agent_window(app)?,
    };
    if layout == AgentLayout::PlaceDefault {
        let physical_size = agent.inner_size().map_err(|error| error.to_string())?;
        let source_scale_factor = agent.scale_factor().map_err(|error| error.to_string())?;
        let requested = logical_size_from_physical(
            (physical_size.width, physical_size.height),
            source_scale_factor,
        );
        let monitor = preferred_monitor(app, AGENT_LABEL)?;
        apply_agent_size_and_position(&agent, geometry(&monitor), requested)?;
    }
    agent.show().map_err(|error| error.to_string())?;
    agent.set_focus().map_err(|error| error.to_string())?;
    Ok(true)
}

fn apply_agent_size_and_position(
    agent: &WebviewWindow,
    monitor: MonitorGeometry,
    requested: (f64, f64),
) -> Result<(), String> {
    let frame = agent_frame(monitor, requested);
    agent
        .set_min_size(Some(LogicalSize::new(
            frame.width.min(432.0),
            frame.height.min(500.0),
        )))
        .map_err(|error| error.to_string())?;
    agent
        .set_size(LogicalSize::new(frame.width, frame.height))
        .map_err(|error| error.to_string())?;
    agent
        .set_position(PhysicalPosition::new(frame.x, frame.y))
        .map_err(|error| error.to_string())
}

fn apply_agent_size_preserving_position(
    agent: &WebviewWindow,
    monitor: MonitorGeometry,
    requested: (f64, f64),
) -> Result<(), String> {
    let fitted = fitted_agent_size(monitor, requested);
    let position = agent.outer_position().map_err(|error| error.to_string())?;
    agent
        .set_min_size(Some(LogicalSize::new(
            fitted.0.min(432.0),
            fitted.1.min(500.0),
        )))
        .map_err(|error| error.to_string())?;
    agent
        .set_size(LogicalSize::new(fitted.0, fitted.1))
        .map_err(|error| error.to_string())?;
    agent
        .set_position(position)
        .map_err(|error| error.to_string())
}

pub fn set_agent_transcript_visible(app: &AppHandle, visible: bool) -> Result<(), String> {
    let Some(agent) = app.get_webview_window(AGENT_LABEL) else {
        return Ok(());
    };
    let window_visible = agent.is_visible().map_err(|error| error.to_string())?;
    if agent_layout_for_transcript_change(window_visible).is_none() {
        return Ok(());
    }
    let monitor = agent
        .current_monitor()
        .map_err(|error| error.to_string())?
        .map(Ok)
        .unwrap_or_else(|| preferred_monitor(app, AGENT_LABEL))?;
    apply_agent_size_preserving_position(
        &agent,
        geometry(&monitor),
        if visible {
            AGENT_SIZE
        } else {
            AGENT_COLLAPSED_SIZE
        },
    )
}

pub fn hide_agent(app: &AppHandle) -> Result<(), String> {
    let Some(agent) = app.get_webview_window(AGENT_LABEL) else {
        return Ok(());
    };
    agent.hide().map_err(|error| error.to_string())
}

pub fn focus_main(app: &AppHandle) -> Result<(), String> {
    let main = app
        .get_webview_window("main")
        .ok_or_else(|| "Arco could not find its main window".to_string())?;
    main.show().map_err(|error| error.to_string())?;
    main.set_focus().map_err(|error| error.to_string())
}

#[cfg(target_os = "macos")]
fn configure_macos_overlay(window: &WebviewWindow, hud: bool) -> Result<(), String> {
    use objc2_app_kit::{NSFloatingWindowLevel, NSWindow, NSWindowCollectionBehavior};

    let raw = window.ns_window().map_err(|error| error.to_string())?;
    // SAFETY: Tauri returns the retained NSWindow backing this WebviewWindow.
    // This runs on the setup thread while the Tauri window remains alive.
    let ns_window = unsafe { &*(raw.cast::<NSWindow>()) };
    let behavior = ns_window.collectionBehavior()
        | NSWindowCollectionBehavior::CanJoinAllSpaces
        | NSWindowCollectionBehavior::FullScreenAuxiliary;
    ns_window.setCollectionBehavior(behavior);
    ns_window.setHidesOnDeactivate(false);
    ns_window.setLevel(NSFloatingWindowLevel + isize::from(hud));
    Ok(())
}

#[cfg(not(target_os = "macos"))]
fn configure_macos_overlay(_window: &WebviewWindow, _hud: bool) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "macos")]
fn finish_overlay_setup(window: &WebviewWindow, is_hud: bool) -> Result<(), String> {
    let setup_window = window.clone();
    let label = window.label().to_string();
    let (send_result, receive_result) = std::sync::mpsc::sync_channel(1);

    window
        .run_on_main_thread(move || {
            material::apply_overlay_material(&setup_window);
            let _ = send_result.send(configure_macos_overlay(&setup_window, is_hud));
        })
        .map_err(|error| format!("could not dispatch {label} setup to the main thread: {error}"))?;

    receive_result
        .recv_timeout(std::time::Duration::from_secs(5))
        .map_err(|error| {
            format!("timed out while configuring {label} on the main thread: {error}")
        })?
        .map_err(|error| format!("could not configure {label} across fullscreen Spaces: {error}"))
}

#[cfg(not(target_os = "macos"))]
fn finish_overlay_setup(window: &WebviewWindow, is_hud: bool) -> Result<(), String> {
    configure_macos_overlay(window, is_hud)
}

fn ensure_hud_window(app: &AppHandle) -> Result<WebviewWindow, String> {
    if let Some(hud) = app.get_webview_window(HUD_LABEL) {
        return Ok(hud);
    }
    let hud = WebviewWindowBuilder::new(
        app,
        HUD_LABEL,
        WebviewUrl::App("index.html?surface=hud".into()),
    )
    .title("Arco Recording")
    .theme(Some(tauri::Theme::Light))
    .inner_size(HUD_SIZE.0, HUD_SIZE.1)
    .resizable(false)
    .maximizable(false)
    .minimizable(false)
    .closable(false)
    .decorations(false)
    .transparent(true)
    .shadow(true)
    .always_on_top(true)
    .visible_on_all_workspaces(true)
    .focused(false)
    .focusable(true)
    .accept_first_mouse(true)
    .visible(false)
    .build()
    .map_err(|error| error.to_string())?;
    if let Err(error) = finish_overlay_setup(&hud, true) {
        let _ = hud.destroy();
        return Err(error);
    }
    Ok(hud)
}

fn ensure_agent_window(app: &AppHandle) -> Result<WebviewWindow, String> {
    if let Some(agent) = app.get_webview_window(AGENT_LABEL) {
        return Ok(agent);
    }
    let agent = WebviewWindowBuilder::new(
        app,
        AGENT_LABEL,
        WebviewUrl::App("index.html?surface=agent-overlay".into()),
    )
    .title("Ask Arco")
    .theme(Some(tauri::Theme::Light))
    .inner_size(AGENT_SIZE.0, AGENT_SIZE.1)
    .min_inner_size(432.0, 500.0)
    .max_inner_size(820.0, 720.0)
    .resizable(true)
    .maximizable(false)
    .minimizable(false)
    .decorations(false)
    .transparent(true)
    .shadow(true)
    .always_on_top(true)
    .visible_on_all_workspaces(true)
    .focused(false)
    .focusable(true)
    .accept_first_mouse(true)
    .visible(false)
    .build()
    .map_err(|error| error.to_string())?;
    if let Err(error) = finish_overlay_setup(&agent, false) {
        let _ = agent.destroy();
        return Err(error);
    }
    Ok(agent)
}

#[cfg(test)]
mod tests {
    use super::{
        agent_frame, agent_layout_for_show, agent_layout_for_transcript_change,
        agent_visibility_after_toggle, capture_surface_labels, hud_position,
        logical_size_from_physical, monitor_fallback_labels, AgentLayout, MonitorGeometry,
        AGENT_COLLAPSED_SIZE, AGENT_LABEL, AGENT_SIZE, HUD_LABEL, HUD_SIZE,
    };

    #[test]
    fn pressing_the_hud_agent_action_again_closes_the_visible_overlay() {
        assert!(agent_visibility_after_toggle(false));
        assert!(!agent_visibility_after_toggle(true));
    }

    #[test]
    fn reopening_an_existing_agent_preserves_the_user_dragged_position() {
        assert_eq!(agent_layout_for_show(false), AgentLayout::PlaceDefault);
        assert_eq!(agent_layout_for_show(true), AgentLayout::PreservePosition);
    }

    #[test]
    fn transcript_updates_resize_a_visible_agent_without_moving_it() {
        assert_eq!(
            agent_layout_for_transcript_change(true),
            Some(AgentLayout::PreservePosition)
        );
    }

    #[test]
    fn transcript_updates_do_not_touch_a_user_hidden_agent() {
        assert_eq!(agent_layout_for_transcript_change(false), None);
    }

    #[test]
    fn active_display_fallback_uses_the_main_window_before_a_stale_agent_window() {
        assert_eq!(monitor_fallback_labels(AGENT_LABEL), ["main", AGENT_LABEL]);
    }

    #[test]
    fn stopping_capture_owns_and_releases_every_global_capture_surface() {
        assert_eq!(capture_surface_labels(), [HUD_LABEL, AGENT_LABEL]);
    }

    #[test]
    fn stopping_capture_hides_surfaces_for_reuse_instead_of_leaking_native_windows() {
        let source = include_str!("overlay.rs");
        let release = source
            .split("pub fn release_capture_surfaces")
            .nth(1)
            .and_then(|tail| tail.split("fn agent_visibility_after_toggle").next())
            .expect("release_capture_surfaces body should remain inspectable");

        assert!(release.contains("window.hide()"));
        assert!(!release.contains("window.destroy()"));
    }

    #[test]
    fn liquid_glass_overlays_do_not_request_a_protected_compositor_surface() {
        let source = include_str!("overlay.rs");
        let hud_builder = source
            .split("fn ensure_hud_window")
            .nth(1)
            .and_then(|tail| tail.split("fn ensure_agent_window").next())
            .expect("HUD builder should remain inspectable");
        let agent_builder = source
            .split("fn ensure_agent_window")
            .nth(1)
            .and_then(|tail| tail.split("#[cfg(test)]").next())
            .expect("Agent builder should remain inspectable");

        assert!(!hud_builder.contains(".content_protected(true)"));
        assert!(!agent_builder.contains(".content_protected(true)"));
    }

    #[test]
    fn app_setup_does_not_eagerly_create_hidden_capture_webviews() {
        let setup_source = include_str!("lib.rs");
        let overlay_source = include_str!("overlay.rs");

        assert!(!setup_source.contains("overlay::create_overlay_windows(app)?"));
        assert!(overlay_source.contains("ensure_hud_window(app)?"));
        assert!(overlay_source.contains("ensure_agent_window(app)?"));
        assert!(overlay_source.contains("release_capture_surfaces"));
    }

    #[test]
    fn native_overlay_mutations_are_dispatched_to_the_macos_main_thread() {
        let overlay_source = include_str!("overlay.rs");
        let main_thread_dispatch = [".run_on_main", "_thread(move ||"].concat();
        let completion_wait = ["recv", "_timeout"].concat();

        assert!(
            overlay_source.contains(&main_thread_dispatch),
            "NSWindow mutations must never run directly on a Tokio command worker"
        );
        assert!(
            overlay_source.contains(&completion_wait),
            "overlay setup must finish before the recording HUD is shown"
        );
    }

    #[test]
    fn moving_from_retina_to_standard_dpi_keeps_the_agent_logical_size() {
        assert_eq!(logical_size_from_physical((1440, 1120), 2.0), AGENT_SIZE);
    }

    #[test]
    fn hud_is_bottom_centered_inside_the_current_monitor_work_area() {
        let monitor = MonitorGeometry {
            x: 0,
            y: 0,
            width: 3024,
            height: 1890,
            scale_factor: 2.0,
        };
        let position = hud_position(monitor);

        assert_eq!(position.x, 1144);
        assert_eq!(position.y, 1730);
        assert_eq!(HUD_SIZE, (368.0, 56.0));
    }

    #[test]
    fn agent_stays_top_right_on_a_monitor_with_a_negative_origin() {
        let monitor = MonitorGeometry {
            x: -1920,
            y: -120,
            width: 1920,
            height: 1080,
            scale_factor: 1.0,
        };
        let frame = agent_frame(monitor, AGENT_SIZE);

        assert_eq!(frame.x, -740);
        assert_eq!(frame.y, -100);
        assert_eq!(frame.width, 720.0);
        assert_eq!(frame.height, 560.0);
        assert_eq!(AGENT_SIZE, (720.0, 560.0));
        assert_eq!(AGENT_COLLAPSED_SIZE, (432.0, 560.0));
    }

    #[test]
    fn agent_frame_fits_inside_a_small_work_area_without_covering_the_hud() {
        let monitor = MonitorGeometry {
            x: 40,
            y: 30,
            width: 320,
            height: 420,
            scale_factor: 1.0,
        };
        let frame = agent_frame(monitor, AGENT_SIZE);

        assert_eq!(hud_position(monitor).x, 40);
        assert_eq!(frame.x, 60);
        assert_eq!(frame.y, 50);
        assert_eq!(frame.width, 280.0);
        assert_eq!(frame.height, 300.0);
        assert!(f64::from(frame.x) + frame.width <= 360.0);
        assert!(f64::from(frame.y) + frame.height <= 450.0);
    }

    #[test]
    fn collapsed_frame_keeps_the_compact_width_on_a_normal_display() {
        let monitor = MonitorGeometry {
            x: 0,
            y: 0,
            width: 1512,
            height: 982,
            scale_factor: 1.0,
        };
        let frame = agent_frame(monitor, AGENT_COLLAPSED_SIZE);

        assert_eq!(frame.x, 1060);
        assert_eq!(frame.y, 20);
        assert_eq!(frame.width, 432.0);
        assert_eq!(frame.height, 560.0);
    }
}
