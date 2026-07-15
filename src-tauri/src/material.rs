#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativeMaterial {
    LiquidGlass,
    Vibrancy,
}

#[cfg(target_os = "macos")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativeSurface {
    Main,
    Hud,
    Agent,
}

#[cfg(target_os = "macos")]
#[derive(Debug, Clone, Copy, PartialEq)]
struct MaterialProfile {
    style: window_vibrancy::NSGlassEffectViewStyle,
    radius: f64,
    active_fallback: bool,
}

#[cfg(target_os = "macos")]
fn material_profile(surface: NativeSurface) -> MaterialProfile {
    use window_vibrancy::NSGlassEffectViewStyle;

    let (radius, active_fallback) = match surface {
        NativeSurface::Main => (20.0, false),
        NativeSurface::Hud => (14.0, true),
        NativeSurface::Agent => (16.0, true),
    };

    MaterialProfile {
        style: NSGlassEffectViewStyle::Regular,
        radius,
        active_fallback,
    }
}

fn material_for_macos_version(version: Option<&str>) -> NativeMaterial {
    let major_version = version.and_then(parse_macos_major_version);

    match major_version {
        Some(version) if version >= 26 => NativeMaterial::LiquidGlass,
        _ => NativeMaterial::Vibrancy,
    }
}

fn parse_macos_major_version(version: &str) -> Option<u32> {
    let mut components = version.trim().split('.');
    let major = components.next()?.parse::<u32>().ok()?;
    components
        .all(|component| !component.is_empty() && component.parse::<u32>().is_ok())
        .then_some(major)
}

#[cfg(target_os = "macos")]
fn macos_product_version() -> Result<String, String> {
    use std::process::Command;

    let output = Command::new("/usr/bin/sw_vers")
        .arg("-productVersion")
        .output()
        .map_err(|error| format!("could not run sw_vers: {error}"))?;

    if !output.status.success() {
        return Err(format!("sw_vers exited with status {}", output.status));
    }

    let version = String::from_utf8(output.stdout)
        .map_err(|error| format!("sw_vers returned invalid UTF-8: {error}"))?
        .trim()
        .to_string();

    if version.is_empty() {
        return Err("sw_vers returned an empty product version".to_string());
    }

    Ok(version)
}

#[cfg(target_os = "macos")]
fn apply_vibrancy_fallback(window: &tauri::WebviewWindow, active: bool) {
    use window_vibrancy::{apply_vibrancy, NSVisualEffectMaterial, NSVisualEffectState};

    if let Err(error) = apply_vibrancy(
        window,
        NSVisualEffectMaterial::UnderWindowBackground,
        Some(if active {
            NSVisualEffectState::Active
        } else {
            NSVisualEffectState::FollowsWindowActiveState
        }),
        Some(22.0),
    ) {
        log::warn!("Arco could not apply the macOS vibrancy fallback: {error}");
    }
}

#[cfg(target_os = "macos")]
pub fn apply_native_material(window: &tauri::WebviewWindow) {
    apply_material(window, NativeSurface::Main);
}

#[cfg(target_os = "macos")]
pub fn apply_hud_material(window: &tauri::WebviewWindow) {
    apply_material(window, NativeSurface::Hud);
}

#[cfg(target_os = "macos")]
pub fn apply_agent_material(window: &tauri::WebviewWindow) {
    apply_material(window, NativeSurface::Agent);
}

#[cfg(target_os = "macos")]
fn apply_material(window: &tauri::WebviewWindow, surface: NativeSurface) {
    use window_vibrancy::apply_liquid_glass;

    let profile = material_profile(surface);
    let version = match macos_product_version() {
        Ok(version) => Some(version),
        Err(error) => {
            log::warn!(
                "Arco could not determine the macOS version ({error}); using vibrancy fallback"
            );
            None
        }
    };

    match material_for_macos_version(version.as_deref()) {
        NativeMaterial::LiquidGlass => {
            if let Err(error) =
                apply_liquid_glass(window, profile.style, None, Some(profile.radius))
            {
                log::warn!(
                    "Arco could not apply Liquid Glass on macOS {} ({error}); using vibrancy fallback",
                    version.as_deref().unwrap_or("unknown")
                );
                apply_vibrancy_fallback(window, profile.active_fallback);
            }
        }
        NativeMaterial::Vibrancy => apply_vibrancy_fallback(window, profile.active_fallback),
    }
}

#[cfg(test)]
mod tests {
    use super::{material_for_macos_version, material_profile, NativeMaterial, NativeSurface};
    use window_vibrancy::NSGlassEffectViewStyle;

    #[test]
    fn macos_26_uses_liquid_glass() {
        assert_eq!(
            material_for_macos_version(Some("26.0")),
            NativeMaterial::LiquidGlass
        );
        assert_eq!(
            material_for_macos_version(Some(" 26.0.1\n")),
            NativeMaterial::LiquidGlass
        );
    }

    #[test]
    fn macos_27_and_newer_keep_using_liquid_glass() {
        assert_eq!(
            material_for_macos_version(Some("27.1.2")),
            NativeMaterial::LiquidGlass
        );
        assert_eq!(
            material_for_macos_version(Some("42.0")),
            NativeMaterial::LiquidGlass
        );
    }

    #[test]
    fn macos_25_boundary_uses_vibrancy() {
        assert_eq!(
            material_for_macos_version(Some("25.9.9")),
            NativeMaterial::Vibrancy
        );
    }

    #[test]
    fn every_surface_uses_regular_glass_to_avoid_clear_overlay_compositor_saturation() {
        assert_eq!(
            material_profile(NativeSurface::Main).style,
            NSGlassEffectViewStyle::Regular
        );
        assert_eq!(
            material_profile(NativeSurface::Hud).style,
            NSGlassEffectViewStyle::Regular
        );
        assert_eq!(
            material_profile(NativeSurface::Agent).style,
            NSGlassEffectViewStyle::Regular
        );
    }

    #[test]
    fn native_glass_radii_are_concentric_with_each_window_surface() {
        assert_eq!(material_profile(NativeSurface::Main).radius, 20.0);
        assert_eq!(material_profile(NativeSurface::Hud).radius, 14.0);
        assert_eq!(material_profile(NativeSurface::Agent).radius, 16.0);
    }

    #[test]
    fn floating_surfaces_keep_the_vibrancy_fallback_active() {
        assert!(!material_profile(NativeSurface::Main).active_fallback);
        assert!(material_profile(NativeSurface::Hud).active_fallback);
        assert!(material_profile(NativeSurface::Agent).active_fallback);
    }

    #[test]
    fn invalid_or_unknown_versions_use_vibrancy() {
        for version in [
            None,
            Some(""),
            Some("Sequoia"),
            Some("26-beta"),
            Some("26..1"),
        ] {
            assert_eq!(
                material_for_macos_version(version),
                NativeMaterial::Vibrancy,
                "expected {version:?} to select the safe fallback"
            );
        }
    }
}
