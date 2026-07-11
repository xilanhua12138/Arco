use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const COMBINED_SESSION_STATE: i32 = 0;
const FN_FLAG_MASK: u64 = 0x0080_0000;
const KEY_CODE_M: u16 = 46;
const POLL_INTERVAL: Duration = Duration::from_millis(20);

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn CGEventSourceFlagsState(state_id: i32) -> u64;
    fn CGEventSourceKeyState(state_id: i32, key: u16) -> u8;
}

#[derive(Default)]
struct FnMEdgeDetector {
    pressed: bool,
}

impl FnMEdgeDetector {
    fn update(&mut self, function_down: bool, m_down: bool) -> bool {
        let down = function_down && m_down;
        let triggered = down && !self.pressed;
        self.pressed = down;
        triggered
    }
}

pub fn start(app: AppHandle) {
    let _ = thread::Builder::new()
        .name("arco-fn-m-shortcut".into())
        .spawn(move || {
            let mut detector = FnMEdgeDetector::default();
            loop {
                let flags = unsafe { CGEventSourceFlagsState(COMBINED_SESSION_STATE) };
                let m_down =
                    unsafe { CGEventSourceKeyState(COMBINED_SESSION_STATE, KEY_CODE_M) } != 0;
                if detector.update(flags & FN_FLAG_MASK != 0, m_down) {
                    let _ = app.emit("arco:fn-m-pressed", ());
                }
                thread::sleep(POLL_INTERVAL);
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fn_m_fires_once_per_press_and_rearms_after_release() {
        let mut detector = FnMEdgeDetector::default();
        assert!(!detector.update(false, false));
        assert!(!detector.update(true, false));
        assert!(detector.update(true, true));
        assert!(!detector.update(true, true));
        assert!(!detector.update(false, true));
        assert!(detector.update(true, true));
    }
}
