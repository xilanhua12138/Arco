#[cfg(target_os = "macos")]
mod macos {
    use objc2::rc::Retained;
    use objc2_app_kit::NSView;
    use std::ffi::{c_char, c_void, CString};
    use std::sync::OnceLock;
    use tauri::Emitter;

    static APP_HANDLE: OnceLock<tauri::AppHandle> = OnceLock::new();

    unsafe extern "C" {
        fn arco_glass_create_action_view(
            tag: isize,
            identifier: *const c_char,
            title: *const c_char,
            symbol: *const c_char,
            enabled: i32,
            variant: i32,
            obscured: i32,
        ) -> *mut c_void;
        fn arco_glass_update_action_view(
            view: *mut c_void,
            title: *const c_char,
            symbol: *const c_char,
            enabled: i32,
            variant: i32,
            obscured: i32,
        ) -> i32;
        fn arco_glass_create_search_view(
            tag: isize,
            value: *const c_char,
            placeholder: *const c_char,
            obscured: i32,
        ) -> *mut c_void;
        fn arco_glass_update_search_view(
            view: *mut c_void,
            value: *const c_char,
            placeholder: *const c_char,
            focus: i32,
            obscured: i32,
        ) -> i32;
        fn arco_glass_create_notes_toolbar_view(
            tag: isize,
            labels_json: *const c_char,
            mode: i32,
            obscured: i32,
        ) -> *mut c_void;
        fn arco_glass_update_notes_toolbar_view(
            view: *mut c_void,
            labels_json: *const c_char,
            mode: i32,
            obscured: i32,
        ) -> i32;
        fn arco_glass_create_surface_view(
            tag: isize,
            corner_radius: f64,
            tone: i32,
            interactive: i32,
            obscured: i32,
        ) -> *mut c_void;
        fn arco_glass_update_surface_view(
            view: *mut c_void,
            corner_radius: f64,
            tone: i32,
            interactive: i32,
            obscured: i32,
        ) -> i32;
        fn arco_native_shell_create_view(
            tag: isize,
            labels_json: *const c_char,
            page: *const c_char,
            capture_phase: *const c_char,
            capture_enabled: i32,
            capture_action_visible: i32,
        ) -> *mut c_void;
        fn arco_native_shell_update_view(
            view: *mut c_void,
            labels_json: *const c_char,
            page: *const c_char,
            capture_phase: *const c_char,
            capture_enabled: i32,
            capture_action_visible: i32,
        ) -> i32;
    }

    fn c_string(value: &str, field: &str) -> Result<CString, String> {
        CString::new(value).map_err(|_| format!("native glass {field} contains a null byte"))
    }

    pub fn register_app(app: &tauri::AppHandle) {
        let _ = APP_HANDLE.set(app.clone());
    }

    #[no_mangle]
    pub extern "C" fn arco_swift_action_callback(identifier: *const c_char) {
        if identifier.is_null() {
            return;
        }
        // SAFETY: Swift passes a valid null-terminated UTF-8 string for this callback.
        let identifier = unsafe { std::ffi::CStr::from_ptr(identifier) }
            .to_string_lossy()
            .into_owned();
        if let Some(app) = APP_HANDLE.get() {
            let _ = app.emit(
                crate::native_action::NATIVE_ACTION_EVENT,
                serde_json::json!({ "id": identifier }),
            );
        }
    }

    #[no_mangle]
    pub extern "C" fn arco_swift_search_callback(value: *const c_char) {
        if value.is_null() {
            return;
        }
        // SAFETY: Swift passes a valid null-terminated UTF-8 string for this callback.
        let value = unsafe { std::ffi::CStr::from_ptr(value) }
            .to_string_lossy()
            .into_owned();
        if let Some(app) = APP_HANDLE.get() {
            let _ = app.emit(crate::native_search::NATIVE_SEARCH_CHANGED_EVENT, value);
        }
    }

    #[no_mangle]
    pub extern "C" fn arco_swift_notes_toolbar_callback(action: *const c_char) {
        if action.is_null() {
            return;
        }
        // SAFETY: Swift passes a valid null-terminated UTF-8 action identifier.
        let action = unsafe { std::ffi::CStr::from_ptr(action) }
            .to_string_lossy()
            .into_owned();
        if let Some(app) = APP_HANDLE.get() {
            let _ = app.emit(
                crate::native_notes_toolbar::NATIVE_NOTES_TOOLBAR_EVENT,
                action,
            );
        }
    }

    #[no_mangle]
    pub extern "C" fn arco_swift_shell_callback(action: *const c_char) {
        if action.is_null() {
            return;
        }
        // SAFETY: Swift passes a valid null-terminated UTF-8 shell action.
        let action = unsafe { std::ffi::CStr::from_ptr(action) }
            .to_string_lossy()
            .into_owned();
        if let Some(app) = APP_HANDLE.get() {
            let _ = app.emit(
                crate::native_shell::NATIVE_SHELL_EVENT,
                serde_json::json!({ "action": action }),
            );
        }
    }

    pub fn create_shell_view(
        tag: isize,
        labels_json: &str,
        page: &str,
        capture_phase: &str,
        capture_enabled: bool,
        capture_action_visible: bool,
    ) -> Result<Retained<NSView>, String> {
        let labels_json = c_string(labels_json, "shell labels")?;
        let page = c_string(page, "shell page")?;
        let capture_phase = c_string(capture_phase, "shell capture phase")?;
        // SAFETY: Swift returns a +1 retained NSView hosting the native shell.
        let raw = unsafe {
            arco_native_shell_create_view(
                tag,
                labels_json.as_ptr(),
                page.as_ptr(),
                capture_phase.as_ptr(),
                i32::from(capture_enabled),
                i32::from(capture_action_visible),
            )
        };
        unsafe { Retained::from_raw(raw.cast::<NSView>()) }
            .ok_or_else(|| "SwiftUI could not create the native shell".to_string())
    }

    pub fn update_shell_view(
        view: &NSView,
        labels_json: &str,
        page: &str,
        capture_phase: &str,
        capture_enabled: bool,
        capture_action_visible: bool,
    ) -> Result<bool, String> {
        let labels_json = c_string(labels_json, "shell labels")?;
        let page = c_string(page, "shell page")?;
        let capture_phase = c_string(capture_phase, "shell capture phase")?;
        // SAFETY: Swift verifies the concrete native-shell host before updating it.
        Ok(unsafe {
            arco_native_shell_update_view(
                (view as *const NSView).cast_mut().cast(),
                labels_json.as_ptr(),
                page.as_ptr(),
                capture_phase.as_ptr(),
                i32::from(capture_enabled),
                i32::from(capture_action_visible),
            ) != 0
        })
    }

    pub fn create_action_view(
        tag: isize,
        identifier: &str,
        title: &str,
        symbol: &str,
        enabled: bool,
        variant: i32,
        obscured: bool,
    ) -> Result<Retained<NSView>, String> {
        let identifier = c_string(identifier, "identifier")?;
        let title = c_string(title, "title")?;
        let symbol = c_string(symbol, "symbol")?;
        // SAFETY: Swift returns a +1 retained NSHostingView, which is an NSView.
        let raw = unsafe {
            arco_glass_create_action_view(
                tag,
                identifier.as_ptr(),
                title.as_ptr(),
                symbol.as_ptr(),
                i32::from(enabled),
                variant,
                i32::from(obscured),
            )
        };
        unsafe { Retained::from_raw(raw.cast::<NSView>()) }
            .ok_or_else(|| "SwiftUI could not create the native action view".to_string())
    }

    pub fn update_action_view(
        view: &NSView,
        title: &str,
        symbol: &str,
        enabled: bool,
        variant: i32,
        obscured: bool,
    ) -> Result<bool, String> {
        let title = c_string(title, "title")?;
        let symbol = c_string(symbol, "symbol")?;
        // SAFETY: Swift verifies the concrete hosting-view subclass before updating it.
        Ok(unsafe {
            arco_glass_update_action_view(
                (view as *const NSView).cast_mut().cast(),
                title.as_ptr(),
                symbol.as_ptr(),
                i32::from(enabled),
                variant,
                i32::from(obscured),
            ) != 0
        })
    }

    pub fn create_search_view(
        tag: isize,
        value: &str,
        placeholder: &str,
        obscured: bool,
    ) -> Result<Retained<NSView>, String> {
        let value = c_string(value, "value")?;
        let placeholder = c_string(placeholder, "placeholder")?;
        // SAFETY: Swift returns a +1 retained NSHostingView, which is an NSView.
        let raw = unsafe {
            arco_glass_create_search_view(
                tag,
                value.as_ptr(),
                placeholder.as_ptr(),
                i32::from(obscured),
            )
        };
        unsafe { Retained::from_raw(raw.cast::<NSView>()) }
            .ok_or_else(|| "SwiftUI could not create the native search view".to_string())
    }

    pub fn update_search_view(
        view: &NSView,
        value: &str,
        placeholder: &str,
        focus: bool,
        obscured: bool,
    ) -> Result<bool, String> {
        let value = c_string(value, "value")?;
        let placeholder = c_string(placeholder, "placeholder")?;
        // SAFETY: Swift verifies the concrete hosting-view subclass before updating it.
        Ok(unsafe {
            arco_glass_update_search_view(
                (view as *const NSView).cast_mut().cast(),
                value.as_ptr(),
                placeholder.as_ptr(),
                i32::from(focus),
                i32::from(obscured),
            ) != 0
        })
    }

    pub fn create_notes_toolbar_view(
        tag: isize,
        labels_json: &str,
        mode: i32,
        obscured: bool,
    ) -> Result<Retained<NSView>, String> {
        let labels_json = c_string(labels_json, "notes toolbar labels")?;
        // SAFETY: Swift returns a +1 retained NSView hosting the SwiftUI toolbar.
        let raw = unsafe {
            arco_glass_create_notes_toolbar_view(
                tag,
                labels_json.as_ptr(),
                mode,
                i32::from(obscured),
            )
        };
        unsafe { Retained::from_raw(raw.cast::<NSView>()) }
            .ok_or_else(|| "SwiftUI could not create the native notes toolbar".to_string())
    }

    pub fn update_notes_toolbar_view(
        view: &NSView,
        labels_json: &str,
        mode: i32,
        obscured: bool,
    ) -> Result<bool, String> {
        let labels_json = c_string(labels_json, "notes toolbar labels")?;
        // SAFETY: Swift verifies the concrete hosting-view subclass before updating it.
        Ok(unsafe {
            arco_glass_update_notes_toolbar_view(
                (view as *const NSView).cast_mut().cast(),
                labels_json.as_ptr(),
                mode,
                i32::from(obscured),
            ) != 0
        })
    }

    pub fn create_surface_view(
        tag: isize,
        corner_radius: f64,
        tone: i32,
        interactive: bool,
        obscured: bool,
    ) -> Result<Retained<NSView>, String> {
        // SAFETY: Swift returns a +1 retained NSHostingView, which is an NSView.
        let raw = unsafe {
            arco_glass_create_surface_view(
                tag,
                corner_radius,
                tone,
                i32::from(interactive),
                i32::from(obscured),
            )
        };
        unsafe { Retained::from_raw(raw.cast::<NSView>()) }
            .ok_or_else(|| "SwiftUI could not create the native glass surface".to_string())
    }

    pub fn update_surface_view(
        view: &NSView,
        corner_radius: f64,
        tone: i32,
        interactive: bool,
        obscured: bool,
    ) -> bool {
        // SAFETY: Swift verifies the concrete hosting-view subclass before updating it.
        unsafe {
            arco_glass_update_surface_view(
                (view as *const NSView).cast_mut().cast(),
                corner_radius,
                tone,
                i32::from(interactive),
                i32::from(obscured),
            ) != 0
        }
    }
}

#[cfg(target_os = "macos")]
pub use macos::*;

#[cfg(test)]
mod tests {
    #[test]
    fn swiftui_bridge_uses_matrix_style_native_glass_primitives() {
        let source = include_str!("../native/ArcoGlassControls.swift");
        let notes_toolbar_bridge = include_str!("native_notes_toolbar.rs");

        assert!(source.contains("GlassEffectContainer(spacing:"));
        assert!(source.contains(".glassEffect(.regular.interactive(), in: Capsule())"));
        assert!(source.contains(".regular.tint(ArcoNativePalette.action).interactive()"));
        assert!(source.contains(".onHover { hovering in"));
        assert!(source.contains(".animation(.smooth(duration: 0.18), value: isHovered)"));
        assert!(source.contains("ArcoNotesToolbarRoot"));
        assert!(!source.contains("Menu {"));
        assert!(source.contains("ArcoFormatPanel"));
        assert!(source.contains(".popover("));
        assert!(source.contains("isPresented: $model.isFormatPresented"));
        assert!(source.contains("if obscured { model.isFormatPresented = false }"));
        assert!(source.contains("content.environment(\\.appearsActive, isActive)"));
        assert!(source.contains(".disabled(!model.isEnabled || model.isObscured)"));
        assert!(!source.contains(".opacity(model.isObscured"));
        assert!(source.contains("ArcoNativeShellRoot"));
        assert!(source.contains("arco_native_shell_create_view"));
        assert!(source.contains("arco_native_shell_update_view"));
        assert!(source.contains("ArcoNativePalette.shellBase.opacity(0.92)"));
        assert!(source.contains(".background(.ultraThickMaterial"));
        assert!(source.contains("toolbarAction(\"table\""));
        assert!(source.contains("inlineAction(\"strikethrough\""));
        assert!(!source.contains("toolbarAction(\"attachment\""));
        assert!(!source.contains("model.activate(\"highlight\")"));
        assert!(!source.contains("inlineAction(\"underline\""));
        assert!(source.contains("panelAction(\"title\""));
        assert!(source.contains("panelAction(\"subheading\""));
        assert!(source.contains("panelAction(\"body\""));
        assert!(source.contains("panelAction(\"monostyled\""));
        assert!(source.contains("panelAction(\"dash\""));
        assert!(source.contains(".regular.tint(model.tint).interactive(model.isInteractive)"));
        assert!(source.contains(".background(.ultraThinMaterial, in: shape)"));
        assert!(notes_toolbar_bridge.contains("view.removeFromSuperview();"));
        assert!(!notes_toolbar_bridge.contains("view.setHidden(true);"));
    }
}
