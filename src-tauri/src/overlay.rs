use tauri::{
    App, AppHandle, LogicalSize, Manager, Monitor, PhysicalPosition, WebviewUrl, WebviewWindow,
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

fn physical_size(logical: (f64, f64), scale_factor: f64) -> (i64, i64) {
    (
        (logical.0 * scale_factor).round() as i64,
        (logical.1 * scale_factor).round() as i64,
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

fn preferred_monitor(app: &AppHandle, surface_label: &str) -> Result<Monitor, String> {
    let labels = if surface_label == AGENT_LABEL {
        [surface_label, "main"]
    } else {
        ["main", surface_label]
    };
    for label in labels {
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
    let hud = set_surface_position(app, HUD_LABEL, hud_position)?;
    hud.show().map_err(|error| error.to_string())
}

pub fn hide_hud(app: &AppHandle) -> Result<(), String> {
    app.get_webview_window(HUD_LABEL)
        .ok_or_else(|| "Arco could not find its recording HUD".to_string())?
        .hide()
        .map_err(|error| error.to_string())
}

pub fn show_or_focus_agent(app: &AppHandle) -> Result<bool, String> {
    let agent = app
        .get_webview_window(AGENT_LABEL)
        .ok_or_else(|| "Arco could not find its Agent window".to_string())?;
    let monitor = preferred_monitor(app, AGENT_LABEL)?;
    let physical_size = agent.inner_size().map_err(|error| error.to_string())?;
    let requested = (
        f64::from(physical_size.width) / monitor.scale_factor(),
        f64::from(physical_size.height) / monitor.scale_factor(),
    );
    apply_agent_size_and_position(&agent, geometry(&monitor), requested)?;
    if !agent.is_visible().map_err(|error| error.to_string())? {
        agent.show().map_err(|error| error.to_string())?;
    }
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

pub fn set_agent_transcript_visible(app: &AppHandle, visible: bool) -> Result<(), String> {
    let agent = app
        .get_webview_window(AGENT_LABEL)
        .ok_or_else(|| "Arco could not find its Agent window".to_string())?;
    let monitor = preferred_monitor(app, AGENT_LABEL)?;
    apply_agent_size_and_position(
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
    app.get_webview_window(AGENT_LABEL)
        .ok_or_else(|| "Arco could not find its Agent window".to_string())?
        .hide()
        .map_err(|error| error.to_string())
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

pub fn create_overlay_windows(app: &App) -> tauri::Result<()> {
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
    .content_protected(true)
    .focused(false)
    .focusable(true)
    .accept_first_mouse(true)
    .visible(false)
    .build()?;

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
    .content_protected(true)
    .focused(false)
    .focusable(true)
    .accept_first_mouse(true)
    .visible(false)
    .build()?;

    #[cfg(target_os = "macos")]
    {
        material::apply_overlay_material(&hud);
        material::apply_overlay_material(&agent);
    }

    for (window, is_hud) in [(&hud, true), (&agent, false)] {
        if let Err(error) = configure_macos_overlay(window, is_hud) {
            log::warn!(
                "Arco could not configure {} across fullscreen Spaces: {error}",
                window.label()
            );
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        agent_frame, hud_position, MonitorGeometry, AGENT_COLLAPSED_SIZE, AGENT_SIZE, HUD_SIZE,
    };

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
