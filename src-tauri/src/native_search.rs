use serde::Deserialize;

pub const NATIVE_SEARCH_CHANGED_EVENT: &str = "arco:native-search-changed";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeSearchFieldState {
    pub x: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
    pub viewport_height: f64,
    pub visible: bool,
    pub obscured: bool,
    pub value: String,
    pub placeholder: String,
    pub focus: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativeSearchPresentation {
    SwiftUiGlassSearch,
    StandardSearchField,
}

fn search_presentation(liquid_glass_available: bool) -> NativeSearchPresentation {
    if liquid_glass_available {
        NativeSearchPresentation::SwiftUiGlassSearch
    } else {
        NativeSearchPresentation::StandardSearchField
    }
}

#[cfg(target_os = "macos")]
fn centered_control_rect(
    rect: objc2_foundation::NSRect,
    control_height: f64,
) -> objc2_foundation::NSRect {
    objc2_foundation::NSRect::new(
        objc2_foundation::NSPoint::new(
            rect.origin.x,
            ((control_height - rect.size.height) / 2.0).max(0.0),
        ),
        rect.size,
    )
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AppKitSearchFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn appkit_search_frame(state: &NativeSearchFieldState) -> Option<AppKitSearchFrame> {
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
    {
        return None;
    }

    let y = state.viewport_height - state.top - state.height;
    y.is_finite().then_some(AppKitSearchFrame {
        x: state.x,
        y,
        width: state.width,
        height: state.height,
    })
}

#[cfg(target_os = "macos")]
mod appkit {
    use super::{
        appkit_search_frame, centered_control_rect, search_presentation, NativeSearchFieldState,
        NativeSearchPresentation, NATIVE_SEARCH_CHANGED_EVENT,
    };
    use objc2::rc::{Allocated, Retained};
    use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{NSControlSize, NSGlassEffectView, NSSearchField, NSView};
    use objc2_foundation::{NSInteger, NSPoint, NSRect, NSSize, NSString};
    use tauri::{Emitter, Manager};

    const NATIVE_SEARCH_FIELD_TAG: NSInteger = 0x4152_434f;
    const NATIVE_SEARCH_GLASS_TAG: NSInteger = 0x4152_4350;

    struct ArcoNativeSearchFieldIvars {
        app: tauri::AppHandle,
    }

    struct ArcoSearchGlassIvars {
        tag: NSInteger,
    }

    define_class!(
        // SAFETY: NSSearchField supports subclassing. The ivars only retain a Tauri handle
        // used to emit value changes back to the WebView.
        #[unsafe(super(NSSearchField))]
        #[name = "ArcoNativeSearchField"]
        #[ivars = ArcoNativeSearchFieldIvars]
        struct ArcoNativeSearchField;

        impl ArcoNativeSearchField {
            #[unsafe(method(arcoSearchChanged:))]
            fn search_changed(&self, sender: &NSSearchField) {
                let value = sender.stringValue().to_string();
                if let Err(error) = self.ivars().app.emit(NATIVE_SEARCH_CHANGED_EVENT, value) {
                    log::warn!("Arco could not emit native search text: {error}");
                }
            }

            #[unsafe(method(searchTextBounds))]
            fn search_text_bounds(&self) -> NSRect {
                // SAFETY: The superclass implementation returns the field editor rectangle
                // for this control. Only its vertical origin is normalized.
                let rect: NSRect = unsafe { msg_send![super(self), searchTextBounds] };
                centered_control_rect(rect, self.bounds().size.height)
            }

            #[unsafe(method(searchButtonBounds))]
            fn search_button_bounds(&self) -> NSRect {
                // SAFETY: The superclass implementation returns the search glyph rectangle
                // for this control. Only its vertical origin is normalized.
                let rect: NSRect = unsafe { msg_send![super(self), searchButtonBounds] };
                centered_control_rect(rect, self.bounds().size.height)
            }

            #[unsafe(method(cancelButtonBounds))]
            fn cancel_button_bounds(&self) -> NSRect {
                // SAFETY: The superclass implementation returns the cancel glyph rectangle
                // for this control. Only its vertical origin is normalized.
                let rect: NSRect = unsafe { msg_send![super(self), cancelButtonBounds] };
                centered_control_rect(rect, self.bounds().size.height)
            }
        }
    );

    define_class!(
        // SAFETY: NSGlassEffectView supports subclassing. The custom subclass only
        // exposes a stable tag so the overlay can be found and updated.
        #[unsafe(super(NSGlassEffectView))]
        #[name = "ArcoSearchGlass"]
        #[ivars = ArcoSearchGlassIvars]
        struct ArcoSearchGlass;

        impl ArcoSearchGlass {
            #[unsafe(method(tag))]
            fn tag(&self) -> NSInteger {
                self.ivars().tag
            }
        }
    );

    impl ArcoNativeSearchField {
        unsafe fn init_with_frame(
            this: Allocated<Self>,
            frame: NSRect,
            app: tauri::AppHandle,
        ) -> Retained<Self> {
            let this = this.set_ivars(ArcoNativeSearchFieldIvars { app });
            // SAFETY: `initWithFrame:` is NSSearchField's designated frame initializer.
            unsafe { msg_send![super(this), initWithFrame: frame] }
        }
    }

    fn sync_on_main_thread(
        window: &tauri::WebviewWindow,
        state: &NativeSearchFieldState,
    ) -> Result<bool, String> {
        let mtm = MainThreadMarker::new().ok_or_else(|| {
            "native search synchronization did not run on the main thread".to_string()
        })?;
        let raw_view = window.ns_view().map_err(|error| error.to_string())?;
        // SAFETY: Tauri owns this NSView for the lifetime of the WebviewWindow, and this
        // function is dispatched to AppKit's main thread before dereferencing it.
        let root_view = unsafe { &*(raw_view.cast::<NSView>()) };

        let existing_view = root_view.viewWithTag(NATIVE_SEARCH_FIELD_TAG);
        let existing = root_view
            .viewWithTag(NATIVE_SEARCH_FIELD_TAG)
            .and_then(|view| view.downcast::<ArcoNativeSearchField>().ok());
        let existing_glass = root_view
            .viewWithTag(NATIVE_SEARCH_GLASS_TAG)
            .and_then(|view| view.downcast::<ArcoSearchGlass>().ok());

        let Some(frame) = appkit_search_frame(state) else {
            if let Some(view) = existing_view.as_ref() {
                view.setHidden(true);
            }
            if let Some(glass) = existing_glass {
                glass.setHidden(true);
            }
            return Ok(true);
        };

        let frame = NSRect::new(
            NSPoint::new(frame.x, frame.y),
            NSSize::new(frame.width, frame.height),
        );
        let presentation = search_presentation(crate::material::liquid_glass_available());
        if presentation == NativeSearchPresentation::SwiftUiGlassSearch {
            if let Some(glass) = existing_glass.as_ref() {
                glass.setHidden(true);
            }
            crate::native_glass::register_app(window.app_handle());
            let updated = existing_view
                .as_ref()
                .map(|view| {
                    crate::native_glass::update_search_view(
                        view,
                        &state.value,
                        &state.placeholder,
                        state.focus,
                        state.obscured,
                    )
                })
                .transpose()?
                .unwrap_or(false);

            if updated {
                let view = existing_view.as_ref().expect("updated view must exist");
                view.setFrame(frame);
                view.setHidden(false);
            } else {
                if let Some(view) = existing_view.as_ref() {
                    view.removeFromSuperview();
                }
                let view = crate::native_glass::create_search_view(
                    NATIVE_SEARCH_FIELD_TAG,
                    &state.value,
                    &state.placeholder,
                    state.obscured,
                )?;
                view.setFrame(frame);
                root_view.addSubview(&view);
                view.setHidden(false);
                if state.focus {
                    let _ = crate::native_glass::update_search_view(
                        &view,
                        &state.value,
                        &state.placeholder,
                        true,
                        state.obscured,
                    )?;
                }
            }
            return Ok(true);
        }

        if existing.is_none() {
            if let Some(view) = existing_view.as_ref() {
                view.removeFromSuperview();
            }
        }
        let search_field_is_new = existing.is_none();
        let search_field = match existing {
            Some(search_field) => search_field,
            None => {
                // SAFETY: Allocation, initialization, target/action setup and view insertion
                // all happen on the AppKit main thread. The superview retains the control;
                // its self-target is weak and remains valid for the same lifetime.
                let search_field = unsafe {
                    ArcoNativeSearchField::init_with_frame(
                        ArcoNativeSearchField::alloc(mtm),
                        frame,
                        window.app_handle().clone(),
                    )
                };
                search_field.setTag(NATIVE_SEARCH_FIELD_TAG);
                search_field.setSendsSearchStringImmediately(true);
                search_field.setControlSize(NSControlSize::Large);
                unsafe {
                    search_field.setTarget(Some(&search_field));
                    search_field.setAction(Some(sel!(arcoSearchChanged:)));
                }
                search_field
            }
        };

        if let Some(glass) = existing_glass {
            glass.setHidden(true);
        }
        debug_assert_eq!(presentation, NativeSearchPresentation::StandardSearchField);
        search_field.setBezeled(true);
        search_field.setDrawsBackground(true);
        search_field.setFrame(frame);
        if search_field_is_new {
            // SAFETY: The root view retains the field, and insertion is on AppKit's
            // main thread.
            root_view.addSubview(&search_field);
        }
        search_field.setHidden(false);
        search_field.setEnabled(!state.obscured);

        let placeholder = NSString::from_str(&state.placeholder);
        search_field.setPlaceholderString(Some(&placeholder));
        if search_field.stringValue().to_string() != state.value {
            let value = NSString::from_str(&state.value);
            search_field.setStringValue(&value);
        }

        if state.focus {
            if let Some(ns_window) = search_field.window() {
                ns_window.makeFirstResponder(Some(&search_field));
            }
        }

        Ok(true)
    }

    pub fn sync(
        window: &tauri::WebviewWindow,
        state: NativeSearchFieldState,
    ) -> Result<bool, String> {
        let setup_window = window.clone();
        let label = window.label().to_string();
        let (send_result, receive_result) = std::sync::mpsc::sync_channel(1);

        window
            .run_on_main_thread(move || {
                let _ = send_result.send(sync_on_main_thread(&setup_window, &state));
            })
            .map_err(|error| {
                format!("could not dispatch {label} native search to AppKit: {error}")
            })?;

        receive_result
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|error| {
                format!("timed out while synchronizing {label} native search: {error}")
            })?
    }
}

#[cfg(target_os = "macos")]
pub fn sync_native_search_field(
    window: &tauri::WebviewWindow,
    state: NativeSearchFieldState,
) -> Result<bool, String> {
    appkit::sync(window, state)
}

#[cfg(not(target_os = "macos"))]
pub fn sync_native_search_field(
    _window: &tauri::WebviewWindow,
    _state: NativeSearchFieldState,
) -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::{
        appkit_search_frame, centered_control_rect, search_presentation, NativeSearchFieldState,
        NativeSearchPresentation,
    };
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    fn state() -> NativeSearchFieldState {
        NativeSearchFieldState {
            x: 32.0,
            top: 48.0,
            width: 260.0,
            height: 38.0,
            viewport_height: 720.0,
            visible: true,
            obscured: false,
            value: "design".to_string(),
            placeholder: "Search".to_string(),
            focus: false,
        }
    }

    #[test]
    fn converts_web_top_left_geometry_to_appkit_bottom_left_geometry() {
        let frame = appkit_search_frame(&state()).expect("valid search field should have a frame");

        assert_eq!(frame.x, 32.0);
        assert_eq!(frame.y, 634.0);
        assert_eq!(frame.width, 260.0);
        assert_eq!(frame.height, 38.0);
    }

    #[test]
    fn hidden_or_non_positive_search_fields_do_not_create_native_controls() {
        let mut hidden = state();
        hidden.visible = false;
        assert_eq!(appkit_search_frame(&hidden), None);

        for (width, height) in [(0.0, 38.0), (-1.0, 38.0), (260.0, 0.0), (260.0, -1.0)] {
            let mut invalid = state();
            invalid.width = width;
            invalid.height = height;
            assert_eq!(
                appkit_search_frame(&invalid),
                None,
                "{width} x {height} must not create a native search field"
            );
        }
    }

    #[test]
    fn non_finite_geometry_is_rejected_before_reaching_appkit() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut invalid = state();
            invalid.x = value;
            assert_eq!(appkit_search_frame(&invalid), None);

            let mut invalid = state();
            invalid.viewport_height = value;
            assert_eq!(appkit_search_frame(&invalid), None);
        }
    }

    #[test]
    fn macos_26_search_routes_to_the_swiftui_glass_bridge() {
        assert_eq!(
            search_presentation(true),
            NativeSearchPresentation::SwiftUiGlassSearch
        );
        assert_eq!(
            search_presentation(false),
            NativeSearchPresentation::StandardSearchField
        );
    }

    #[test]
    fn native_search_text_and_icons_share_the_glass_vertical_center() {
        let rect = centered_control_rect(
            NSRect::new(NSPoint::new(8.0, 19.0), NSSize::new(180.0, 16.0)),
            32.0,
        );

        assert_eq!(rect.origin.x, 8.0);
        assert_eq!(rect.origin.y, 8.0);
        assert_eq!(rect.size.width, 180.0);
        assert_eq!(rect.size.height, 16.0);
    }
}
