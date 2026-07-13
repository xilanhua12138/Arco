use tauri::{AppHandle, Emitter, Runtime};
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

pub const DEFAULT_LISTENING_SHORTCUT: &str = "CommandOrControl+Shift+Space";
pub const LISTENING_SHORTCUT_PRESSED_EVENT: &str = "arco:listening-shortcut-pressed";

pub fn register_default<R: Runtime>(app: &AppHandle<R>) -> Result<(), String> {
    let shortcuts = app.global_shortcut();
    if shortcuts.is_registered(DEFAULT_LISTENING_SHORTCUT) {
        return Ok(());
    }

    shortcuts
        .on_shortcut(DEFAULT_LISTENING_SHORTCUT, |app, _, event| {
            if event.state == ShortcutState::Pressed {
                let _ = app.emit(LISTENING_SHORTCUT_PRESSED_EVENT, ());
            }
        })
        .map_err(|error| format!("macOS could not register the Arco shortcut: {error}"))
}

#[cfg(test)]
mod tests {
    use super::DEFAULT_LISTENING_SHORTCUT;
    use tauri_plugin_global_shortcut::ShortcutWrapper;

    #[test]
    fn default_listening_shortcut_is_accepted_by_the_native_plugin() {
        assert!(ShortcutWrapper::try_from(DEFAULT_LISTENING_SHORTCUT).is_ok());
    }
}
