use objc2::rc::Retained;
use objc2::{AnyThread, MainThreadMarker};
#[cfg(test)]
use objc2_app_kit::NSBitmapImageRep;
use objc2_app_kit::{NSApplication, NSImage, NSWindow};
use objc2_foundation::NSData;

const ARCO_DOCK_ICON_PNG: &[u8] = include_bytes!("../../public/arco-app-icon.png");

#[cfg(test)]
pub(crate) fn load_bitmap() -> Result<Retained<NSBitmapImageRep>, String> {
    let data = NSData::with_bytes(ARCO_DOCK_ICON_PNG);
    NSBitmapImageRep::imageRepWithData(&data)
        .ok_or_else(|| "Arco dock icon bitmap could not be decoded".to_string())
}

pub(crate) fn load() -> Result<Retained<NSImage>, String> {
    let data = NSData::with_bytes(ARCO_DOCK_ICON_PNG);
    NSImage::initWithData(NSImage::alloc(), &data)
        .ok_or_else(|| "Arco app icon could not be decoded".to_string())
}

pub(crate) fn apply() -> Result<(), String> {
    let main_thread = MainThreadMarker::new()
        .ok_or_else(|| "Arco dock icon must be installed from the main thread".to_string())?;
    let image = load()?;
    let application = NSApplication::sharedApplication(main_thread);

    // macOS 26+ wraps irregular legacy ICNS artwork in a generated gray
    // enclosure. Arco supplies its own white rounded tile so the Dock and
    // minimized-window treatments stay consistent across OS versions.
    unsafe { application.setApplicationIconImage(Some(&image)) };
    Ok(())
}

pub(crate) fn apply_to_window(window: &tauri::WebviewWindow) -> Result<(), String> {
    let raw_window = window.ns_window().map_err(|error| error.to_string())?;
    let image = load()?;

    // SAFETY: Tauri guarantees that `ns_window` returns the live NSWindow for
    // this WebviewWindow on macOS. App setup runs on the main thread.
    let native_window = unsafe { &*raw_window.cast::<NSWindow>() };
    native_window.setMiniwindowImage(Some(&image));
    Ok(())
}
