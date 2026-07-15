use serde::{Deserialize, Serialize};

pub const NATIVE_ACTION_EVENT: &str = "arco:native-action";

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum NativeActionVariant {
    Prominent,
    Standard,
    Toolbar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum NativeActionPresentation {
    SwiftUiTintedCapsule,
    SwiftUiRegularCapsule,
    SwiftUiClearCircle,
    StandardButton,
}

fn action_presentation(
    variant: NativeActionVariant,
    liquid_glass_available: bool,
) -> NativeActionPresentation {
    match (variant, liquid_glass_available) {
        (NativeActionVariant::Toolbar, true) => NativeActionPresentation::SwiftUiClearCircle,
        (NativeActionVariant::Prominent, true) => NativeActionPresentation::SwiftUiTintedCapsule,
        (NativeActionVariant::Standard, true) => NativeActionPresentation::SwiftUiRegularCapsule,
        _ => NativeActionPresentation::StandardButton,
    }
}

fn swiftui_action_variant(variant: NativeActionVariant) -> i32 {
    match variant {
        NativeActionVariant::Prominent => 0,
        NativeActionVariant::Standard => 1,
        NativeActionVariant::Toolbar => 2,
    }
}

fn native_action_icon_size(variant: NativeActionVariant) -> f64 {
    match variant {
        NativeActionVariant::Toolbar => 12.0,
        NativeActionVariant::Prominent | NativeActionVariant::Standard => 14.0,
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeActionButtonState {
    pub id: String,
    pub x: f64,
    pub top: f64,
    pub width: f64,
    pub height: f64,
    pub viewport_height: f64,
    pub visible: bool,
    pub obscured: bool,
    pub title: String,
    pub symbol: String,
    pub enabled: bool,
    pub variant: NativeActionVariant,
}

#[derive(Debug, Clone, Serialize)]
struct NativeActionEvent {
    id: String,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct AppKitActionFrame {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

fn native_action_tag(id: &str) -> Option<isize> {
    match id {
        "notes-new" => Some(0x4152_4101),
        "notes-list-toggle" => Some(0x4152_4102),
        "settings-open" => Some(0x4152_4103),
        "capture-toggle" => Some(0x4152_4104),
        _ => None,
    }
}

fn native_action_glass_tag(id: &str) -> Option<isize> {
    native_action_tag(id).map(|tag| tag + 0x100)
}

fn appkit_action_frame(state: &NativeActionButtonState) -> Option<AppKitActionFrame> {
    let geometry = [
        state.x,
        state.top,
        state.width,
        state.height,
        state.viewport_height,
    ];
    if !state.visible
        || native_action_tag(&state.id).is_none()
        || geometry.iter().any(|value| !value.is_finite())
        || state.width <= 0.0
        || state.height <= 0.0
        || state.viewport_height <= 0.0
    {
        return None;
    }

    let y = state.viewport_height - state.top - state.height;
    y.is_finite().then_some(AppKitActionFrame {
        x: state.x,
        y,
        width: state.width,
        height: state.height,
    })
}

#[cfg(target_os = "macos")]
mod appkit {
    use super::{
        action_presentation, appkit_action_frame, native_action_glass_tag, native_action_icon_size,
        native_action_tag, swiftui_action_variant, NativeActionButtonState, NativeActionEvent,
        NativeActionPresentation, NativeActionVariant, NATIVE_ACTION_EVENT,
    };
    use objc2::rc::{Allocated, Retained};
    use objc2::{define_class, msg_send, sel, DefinedClass, MainThreadMarker, MainThreadOnly};
    use objc2_app_kit::{
        NSBezelStyle, NSButton, NSCellImagePosition, NSControlSize, NSGlassEffectView, NSImage,
        NSView,
    };
    use objc2_foundation::{NSInteger, NSPoint, NSRect, NSSize, NSString};
    use tauri::{Emitter, Manager};

    struct ArcoNativeActionButtonIvars {
        app: tauri::AppHandle,
        id: String,
    }

    struct ArcoActionGlassIvars {
        tag: NSInteger,
    }

    define_class!(
        // SAFETY: NSButton supports subclassing. The ivars retain only the Tauri handle
        // and stable action identifier needed to send the click back to React.
        #[unsafe(super(NSButton))]
        #[name = "ArcoNativeActionButton"]
        #[ivars = ArcoNativeActionButtonIvars]
        struct ArcoNativeActionButton;

        impl ArcoNativeActionButton {
            #[unsafe(method(arcoActionPressed:))]
            fn action_pressed(&self, _sender: &NSButton) {
                let event = NativeActionEvent { id: self.ivars().id.clone() };
                if let Err(error) = self.ivars().app.emit(NATIVE_ACTION_EVENT, event) {
                    log::warn!("Arco could not emit native action: {error}");
                }
            }
        }
    );

    define_class!(
        // SAFETY: NSGlassEffectView supports subclassing. This subclass only provides
        // a stable tag so the native overlay can be found and updated.
        #[unsafe(super(NSGlassEffectView))]
        #[name = "ArcoActionGlass"]
        #[ivars = ArcoActionGlassIvars]
        struct ArcoActionGlass;

        impl ArcoActionGlass {
            #[unsafe(method(tag))]
            fn tag(&self) -> NSInteger {
                self.ivars().tag
            }
        }
    );

    impl ArcoNativeActionButton {
        unsafe fn init_with_frame(
            this: Allocated<Self>,
            frame: NSRect,
            app: tauri::AppHandle,
            id: String,
        ) -> Retained<Self> {
            let this = this.set_ivars(ArcoNativeActionButtonIvars { app, id });
            // SAFETY: `initWithFrame:` is NSButton's inherited frame initializer.
            unsafe { msg_send![super(this), initWithFrame: frame] }
        }
    }

    fn fallback_bezel(variant: NativeActionVariant) -> NSBezelStyle {
        match variant {
            NativeActionVariant::Prominent | NativeActionVariant::Standard => NSBezelStyle::Push,
            NativeActionVariant::Toolbar => NSBezelStyle::Circular,
        }
    }

    fn sync_on_main_thread(
        window: &tauri::WebviewWindow,
        state: &NativeActionButtonState,
    ) -> Result<bool, String> {
        let tag = native_action_tag(&state.id)
            .ok_or_else(|| format!("{} is not an approved native action", state.id))?
            as NSInteger;
        let glass_tag = native_action_glass_tag(&state.id)
            .ok_or_else(|| format!("{} has no native glass tag", state.id))?
            as NSInteger;
        let mtm = MainThreadMarker::new().ok_or_else(|| {
            "native action synchronization did not run on the main thread".to_string()
        })?;
        let raw_view = window.ns_view().map_err(|error| error.to_string())?;
        // SAFETY: Tauri owns the NSView for the WebviewWindow lifetime, and this runs
        // exclusively on AppKit's main thread.
        let root_view = unsafe { &*(raw_view.cast::<NSView>()) };
        let existing_view = root_view.viewWithTag(tag);
        let existing = root_view
            .viewWithTag(tag)
            .and_then(|view| view.downcast::<ArcoNativeActionButton>().ok());
        let existing_glass = root_view
            .viewWithTag(glass_tag)
            .and_then(|view| view.downcast::<ArcoActionGlass>().ok());

        let Some(frame) = appkit_action_frame(state) else {
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
        let presentation =
            action_presentation(state.variant, crate::material::liquid_glass_available());

        if matches!(
            presentation,
            NativeActionPresentation::SwiftUiTintedCapsule
                | NativeActionPresentation::SwiftUiRegularCapsule
                | NativeActionPresentation::SwiftUiClearCircle
        ) {
            if let Some(glass) = existing_glass.as_ref() {
                glass.setHidden(true);
            }
            crate::native_glass::register_app(window.app_handle());
            let variant = swiftui_action_variant(state.variant);
            let updated = existing_view
                .as_ref()
                .map(|view| {
                    crate::native_glass::update_action_view(
                        view,
                        &state.title,
                        &state.symbol,
                        state.enabled,
                        variant,
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
                let view = crate::native_glass::create_action_view(
                    tag,
                    &state.id,
                    &state.title,
                    &state.symbol,
                    state.enabled,
                    variant,
                    state.obscured,
                )?;
                view.setFrame(frame);
                root_view.addSubview(&view);
                view.setHidden(false);
            }
            return Ok(true);
        }

        if existing.is_none() {
            if let Some(view) = existing_view.as_ref() {
                view.removeFromSuperview();
            }
        }

        let button = match existing {
            Some(button) => button,
            None => {
                // SAFETY: Allocation and action setup happen on AppKit's main thread.
                // The selected presentation's superview retains the button.
                let button = unsafe {
                    ArcoNativeActionButton::init_with_frame(
                        ArcoNativeActionButton::alloc(mtm),
                        frame,
                        window.app_handle().clone(),
                        state.id.clone(),
                    )
                };
                button.setTag(tag);
                unsafe {
                    button.setTarget(Some(&button));
                    button.setAction(Some(sel!(arcoActionPressed:)));
                }
                button
            }
        };

        button.setHidden(false);
        button.setEnabled(state.enabled && !state.obscured);
        button.setControlSize(match state.variant {
            NativeActionVariant::Prominent => NSControlSize::Large,
            NativeActionVariant::Standard | NativeActionVariant::Toolbar => NSControlSize::Regular,
        });
        if let Some(glass) = existing_glass {
            glass.setHidden(true);
        }
        debug_assert_eq!(presentation, NativeActionPresentation::StandardButton);
        button.setFrame(frame);
        button.setBordered(true);
        button.setTransparent(false);
        button.setBezelStyle(fallback_bezel(state.variant));
        button.setBezelColor(None);
        // SAFETY: The button is retained locally and queried on AppKit's main thread.
        if unsafe { button.superview() }.is_none() {
            root_view.addSubview(&button);
        }

        let visible_title = match state.variant {
            NativeActionVariant::Toolbar => "",
            NativeActionVariant::Prominent | NativeActionVariant::Standard => &state.title,
        };
        button.setTitle(&NSString::from_str(visible_title));
        if let Some(image) = NSImage::imageWithSystemSymbolName_accessibilityDescription(
            &NSString::from_str(&state.symbol),
            Some(&NSString::from_str(&state.title)),
        ) {
            let icon_size = native_action_icon_size(state.variant);
            image.setSize(NSSize::new(icon_size, icon_size));
            button.setImage(Some(&image));
            button.setImagePosition(match state.variant {
                NativeActionVariant::Toolbar => NSCellImagePosition::ImageOnly,
                NativeActionVariant::Prominent | NativeActionVariant::Standard => {
                    NSCellImagePosition::ImageLeading
                }
            });
            button.setImageHugsTitle(true);
        }

        Ok(true)
    }

    pub fn sync(
        window: &tauri::WebviewWindow,
        state: NativeActionButtonState,
    ) -> Result<bool, String> {
        let setup_window = window.clone();
        let label = window.label().to_string();
        let (send_result, receive_result) = std::sync::mpsc::sync_channel(1);
        window
            .run_on_main_thread(move || {
                let _ = send_result.send(sync_on_main_thread(&setup_window, &state));
            })
            .map_err(|error| {
                format!("could not dispatch {label} native action to AppKit: {error}")
            })?;
        receive_result
            .recv_timeout(std::time::Duration::from_secs(5))
            .map_err(|error| {
                format!("timed out while synchronizing {label} native action: {error}")
            })?
    }
}

#[cfg(target_os = "macos")]
pub fn sync_native_action_button(
    window: &tauri::WebviewWindow,
    state: NativeActionButtonState,
) -> Result<bool, String> {
    appkit::sync(window, state)
}

#[cfg(not(target_os = "macos"))]
pub fn sync_native_action_button(
    _window: &tauri::WebviewWindow,
    _state: NativeActionButtonState,
) -> Result<bool, String> {
    Ok(false)
}

#[cfg(test)]
mod tests {
    use super::{
        action_presentation, appkit_action_frame, native_action_icon_size, native_action_tag,
        NativeActionButtonState, NativeActionPresentation, NativeActionVariant,
    };

    fn state() -> NativeActionButtonState {
        NativeActionButtonState {
            id: "notes-new".to_string(),
            x: 620.0,
            top: 48.0,
            width: 112.0,
            height: 36.0,
            viewport_height: 720.0,
            visible: true,
            obscured: false,
            title: "New note".to_string(),
            symbol: "plus".to_string(),
            enabled: true,
            variant: NativeActionVariant::Prominent,
        }
    }

    #[test]
    fn converts_action_geometry_to_appkit_coordinates() {
        let frame = appkit_action_frame(&state()).expect("valid action should have a frame");
        assert_eq!(frame.x, 620.0);
        assert_eq!(frame.y, 636.0);
        assert_eq!(frame.width, 112.0);
        assert_eq!(frame.height, 36.0);
    }

    #[test]
    fn only_reviewed_functional_layer_actions_receive_native_overlays() {
        assert_ne!(native_action_tag("notes-new"), None);
        assert_ne!(native_action_tag("notes-list-toggle"), None);
        assert_ne!(native_action_tag("settings-open"), None);
        assert_ne!(native_action_tag("capture-toggle"), None);
        assert_eq!(native_action_tag("notes-save"), None);
        assert_eq!(native_action_tag("format-bold"), None);
        assert_eq!(native_action_tag("meeting-row"), None);
    }

    #[test]
    fn hidden_invalid_or_unknown_actions_never_reach_appkit() {
        let mut hidden = state();
        hidden.visible = false;
        assert_eq!(appkit_action_frame(&hidden), None);

        let mut unknown = state();
        unknown.id = "unreviewed-action".to_string();
        assert_eq!(appkit_action_frame(&unknown), None);

        for value in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            let mut invalid = state();
            invalid.width = value;
            assert_eq!(appkit_action_frame(&invalid), None);
        }
    }

    #[test]
    fn macos_26_actions_route_to_swiftui_glass_shapes() {
        assert_eq!(
            action_presentation(NativeActionVariant::Toolbar, true),
            NativeActionPresentation::SwiftUiClearCircle
        );
        assert_eq!(
            action_presentation(NativeActionVariant::Prominent, true),
            NativeActionPresentation::SwiftUiTintedCapsule
        );
        assert_eq!(native_action_icon_size(NativeActionVariant::Toolbar), 12.0);
    }
}
