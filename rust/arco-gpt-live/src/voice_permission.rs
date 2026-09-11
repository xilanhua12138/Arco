//! A playback gate based on the human transcript, in addition to model instructions.
use std::sync::{
    Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Default)]
pub struct VoicePermission {
    until: AtomicU64,
    input: Mutex<(String, bool)>,
}
impl VoicePermission {
    pub fn input(&self, text: &str, final_text: bool) {
        let mut input = self.input.lock().unwrap();
        if input.1 {
            input.0.clear();
            input.1 = false;
        }
        if final_text && !text.is_empty() {
            input.0 = text.to_owned();
        } else if input.0.len() + text.len() <= 16_384 {
            input.0.push_str(text);
        }
        self.until.store(
            if addressed(&input.0) { now_ms() + 45_000 } else { 0 },
            Ordering::Release,
        );
        input.1 = final_text;
    }
    pub fn allowed(&self) -> bool {
        self.until.load(Ordering::Acquire) > now_ms()
    }
}
fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}
fn addressed(text: &str) -> bool {
    let normalized = text
        .trim_start_matches(|c: char| c.is_whitespace() || "\"'“‘，,。.!！?？".contains(c))
        .to_lowercase();
    ["arco", "hey arco", "hi arco", "阿可", "嘿阿可", "嘿，阿可"]
        .iter().any(|prefix| {
            normalized.strip_prefix(prefix).is_some_and(|rest| {
                !rest.chars().next().is_some_and(|c| c.is_ascii_alphanumeric())
            })
        })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_addressed_human_turns_allow_playback() {
        let gate = VoicePermission::default();
        assert!(!gate.allowed());
        gate.input("我们下周发布，你觉得呢？", true);
        assert!(!gate.allowed());
        gate.input("Arco，总结刚才的决定。", true);
        assert!(gate.allowed());
        gate.input("嗯，我赞同。", true);
        assert!(!gate.allowed());
        gate.input("我们在讨论 Arco 的功能。", true);
        assert!(!gate.allowed());
        gate.input("Marco, hello", true);
        assert!(!gate.allowed());
        gate.input("Hey Arco, what did we decide?", true);
        assert!(gate.allowed());
    }
    #[test]
    fn partial_name_and_final_correction_are_handled() {
        let gate = VoicePermission::default();
        gate.input("Ar", false);
        assert!(!gate.allowed());
        gate.input("co，总结一下", false);
        assert!(gate.allowed());
        gate.input("Marco，总结一下", true);
        assert!(!gate.allowed());
        gate.input("阿可，帮我回顾", true);
        assert!(gate.allowed());
    }
}
