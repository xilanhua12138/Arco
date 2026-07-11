#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativeMaterial {
    LiquidGlass,
    Vibrancy,
}

fn material_for_macos_version(version: Option<&str>) -> NativeMaterial {
    let major_version = version.and_then(parse_macos_major_version);

    match major_version {
        Some(26..) => NativeMaterial::LiquidGlass,
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
    apply_material(window, false);
}

#[cfg(target_os = "macos")]
pub fn apply_overlay_material(window: &tauri::WebviewWindow) {
    apply_material(window, true);
}

#[cfg(target_os = "macos")]
fn glass_style_for_surface(overlay: bool) -> window_vibrancy::NSGlassEffectViewStyle {
    use window_vibrancy::NSGlassEffectViewStyle;

    if overlay {
        NSGlassEffectViewStyle::Clear
    } else {
        NSGlassEffectViewStyle::Regular
    }
}

#[cfg(target_os = "macos")]
fn apply_material(window: &tauri::WebviewWindow, overlay: bool) {
    use window_vibrancy::apply_liquid_glass;

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
            let style = glass_style_for_surface(overlay);
            let radius = if overlay { 16.0 } else { 20.0 };
            if let Err(error) = apply_liquid_glass(window, style, None, Some(radius)) {
                log::warn!(
                    "Arco could not apply Liquid Glass on macOS {} ({error}); using vibrancy fallback",
                    version.as_deref().unwrap_or("unknown")
                );
                apply_vibrancy_fallback(window, overlay);
            }
        }
        NativeMaterial::Vibrancy => apply_vibrancy_fallback(window, overlay),
    }
}

#[cfg(test)]
mod tests {
    use super::{glass_style_for_surface, material_for_macos_version, NativeMaterial};
    use window_vibrancy::NSGlassEffectViewStyle;

    #[test]
    fn macos_26_and_newer_use_liquid_glass() {
        assert_eq!(
            material_for_macos_version(Some("26.0")),
            NativeMaterial::LiquidGlass
        );
        assert_eq!(
            material_for_macos_version(Some("27.1.2")),
            NativeMaterial::LiquidGlass
        );
        assert_eq!(
            material_for_macos_version(Some(" 26.0.1\n")),
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
    fn main_window_uses_regular_glass_while_utility_windows_stay_clear() {
        assert_eq!(
            glass_style_for_surface(false),
            NSGlassEffectViewStyle::Regular
        );
        assert_eq!(glass_style_for_surface(true), NSGlassEffectViewStyle::Clear);
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
