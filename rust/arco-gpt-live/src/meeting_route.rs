//! Own the temporary system microphone route independently of the AI session.
//! The OS releases our advisory lock even after SIGKILL; the journal permits
//! recovery next launch, without overriding a device the user selected meanwhile.
use serde_json::json;
use std::fs::{File, OpenOptions};
use std::os::fd::AsRawFd;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

#[cfg(target_os = "macos")]
mod hardware {
    use std::ffi::{c_char, c_void};
    #[repr(C)]
    struct Address {
        selector: u32,
        scope: u32,
        element: u32,
    }
    const fn code(v: &[u8; 4]) -> u32 {
        u32::from_be_bytes(*v)
    }
    #[link(name = "CoreAudio", kind = "framework")]
    unsafe extern "C" {
        fn AudioObjectGetPropertyData(
            id: u32,
            a: *const Address,
            q: u32,
            qp: *const c_void,
            size: *mut u32,
            out: *mut c_void,
        ) -> i32;
        fn AudioObjectGetPropertyDataSize(
            id: u32,
            a: *const Address,
            q: u32,
            qp: *const c_void,
            size: *mut u32,
        ) -> i32;
        fn AudioObjectSetPropertyData(
            id: u32,
            a: *const Address,
            q: u32,
            qp: *const c_void,
            size: u32,
            data: *const c_void,
        ) -> i32;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringGetCString(s: *const c_void, b: *mut c_char, len: isize, enc: u32) -> bool;
        fn CFRelease(s: *const c_void);
    }
    fn address(selector: u32) -> Address {
        Address {
            selector,
            scope: code(b"glob"),
            element: 0,
        }
    }
    fn read_u32(id: u32, selector: u32) -> Result<u32, String> {
        let mut value = 0u32;
        let mut size = 4;
        let status = unsafe {
            AudioObjectGetPropertyData(
                id,
                &address(selector),
                0,
                std::ptr::null(),
                &mut size,
                (&mut value as *mut u32).cast(),
            )
        };
        if status == 0 {
            Ok(value)
        } else {
            Err(format!("Audio device read failed ({status})"))
        }
    }
    pub fn uid(id: u32) -> Result<String, String> {
        let mut value: *const c_void = std::ptr::null();
        let mut size = std::mem::size_of_val(&value) as u32;
        let status = unsafe {
            AudioObjectGetPropertyData(
                id,
                &address(code(b"uid ")),
                0,
                std::ptr::null(),
                &mut size,
                (&mut value as *mut *const c_void).cast(),
            )
        };
        if status != 0 || value.is_null() {
            return Err("Audio device UID is unavailable".into());
        }
        let mut bytes = vec![0u8; 4096];
        let ok = unsafe {
            CFStringGetCString(
                value,
                bytes.as_mut_ptr().cast(),
                bytes.len() as isize,
                0x08000100,
            )
        };
        unsafe { CFRelease(value) };
        if !ok {
            return Err("Audio device UID is too long".into());
        }
        let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
        String::from_utf8(bytes[..end].to_vec()).map_err(|_| "Invalid audio UID".into())
    }
    pub fn devices() -> Vec<u32> {
        let a = address(code(b"dev#"));
        let mut size = 0;
        if unsafe { AudioObjectGetPropertyDataSize(1, &a, 0, std::ptr::null(), &mut size) } != 0 {
            return vec![];
        }
        let mut values = vec![0u32; size as usize / 4];
        if unsafe {
            AudioObjectGetPropertyData(
                1,
                &a,
                0,
                std::ptr::null(),
                &mut size,
                values.as_mut_ptr().cast(),
            )
        } != 0
        {
            return vec![];
        }
        values
    }
    pub fn find(uid_value: &str) -> Option<u32> {
        devices()
            .into_iter()
            .find(|id| uid(*id).as_deref() == Ok(uid_value))
    }
    pub fn gain(id: u32, input: bool) -> Option<f32> {
        let a = Address {
            selector: code(b"volm"),
            scope: code(if input { b"inpt" } else { b"outp" }),
            element: 0,
        };
        let mut v = 0f32;
        let mut size = 4;
        (unsafe {
            AudioObjectGetPropertyData(
                id,
                &a,
                0,
                std::ptr::null(),
                &mut size,
                (&mut v as *mut f32).cast(),
            )
        } == 0)
            .then_some(v)
    }
    pub fn set_gain(id: u32, input: bool, gain: f32) {
        let a = Address {
            selector: code(b"volm"),
            scope: code(if input { b"inpt" } else { b"outp" }),
            element: 0,
        };
        unsafe {
            AudioObjectSetPropertyData(
                id,
                &a,
                0,
                std::ptr::null(),
                4,
                (&gain as *const f32).cast(),
            );
        }
    }
    pub fn keep_alerts_on_speakers() {
        if read_u32(1, code(b"sOut")).and_then(uid).as_deref() == Ok(super::VIRTUAL_UID) {
            if let Ok(id) = read_u32(1, code(b"dOut")) {
                if uid(id).as_deref() != Ok(super::VIRTUAL_UID) {
                    unsafe {
                        AudioObjectSetPropertyData(
                            1,
                            &address(code(b"sOut")),
                            0,
                            std::ptr::null(),
                            4,
                            (&id as *const u32).cast(),
                        );
                    }
                }
            }
        }
    }
    pub fn default_input() -> Result<u32, String> {
        read_u32(1, code(b"dIn "))
    }
    pub fn set_default(id: u32) -> Result<(), String> {
        let status = unsafe {
            AudioObjectSetPropertyData(
                1,
                &address(code(b"dIn ")),
                0,
                std::ptr::null(),
                4,
                (&id as *const u32).cast(),
            )
        };
        if status == 0 {
            Ok(())
        } else {
            Err(format!("Could not connect meeting microphone ({status})"))
        }
    }
    pub fn physical(id: u32) -> bool {
        let t = read_u32(id, code(b"tran")).unwrap_or(0);
        let mut a = address(code(b"stm#"));
        a.scope = code(b"inpt");
        let mut size = 0;
        t != code(b"virt")
            && t != code(b"grup")
            && unsafe { AudioObjectGetPropertyDataSize(id, &a, 0, std::ptr::null(), &mut size) }
                == 0
            && size > 0
    }
}
#[cfg(not(target_os = "macos"))]
mod hardware {
    pub fn gain(_: u32, _: bool) -> Option<f32> {
        None
    }
    pub fn set_gain(_: u32, _: bool, _: f32) {}
    pub fn keep_alerts_on_speakers() {}
    pub fn uid(_: u32) -> Result<String, String> {
        Err("macOS is required".into())
    }
    pub fn default_input() -> Result<u32, String> {
        Err("macOS is required".into())
    }
    pub fn set_default(_: u32) -> Result<(), String> {
        Err("macOS is required".into())
    }
    pub fn find(_: &str) -> Option<u32> {
        None
    }
    pub fn devices() -> Vec<u32> {
        vec![]
    }
    pub fn physical(_: u32) -> bool {
        false
    }
}

pub const VIRTUAL_UID: &str = "BlackHole2ch_UID";
fn directory() -> Result<PathBuf, String> {
    let path =
        PathBuf::from(std::env::var_os("HOME").ok_or("Home directory unavailable")?).join(".arco");
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    Ok(path)
}
fn journal() -> Result<PathBuf, String> {
    Ok(directory()?.join("meeting-audio-route.json"))
}
fn lock() -> Result<File, String> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(directory()?.join("meeting-audio-route.lock"))
        .map_err(|e| e.to_string())?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return Err("Another Arco meeting owns the microphone".into());
    }
    Ok(file)
}
fn saved_uid() -> Option<String> {
    let data = std::fs::read(journal().ok()?).ok()?;
    let value: serde_json::Value = serde_json::from_slice(&data).ok()?;
    value.get("originalUID")?.as_str().map(str::to_string)
}
pub fn physical_microphone_uid() -> Result<String, String> {
    if let Ok(configured) = std::env::var("ARCO_MIC_DEVICE_ID") {
        if hardware::find(&configured).is_some_and(hardware::physical) {
            return Ok(configured);
        }
    }
    let current = hardware::default_input()?;
    if hardware::physical(current) {
        return hardware::uid(current);
    }
    if let Some(saved) = saved_uid().filter(|v| hardware::find(v).is_some_and(hardware::physical)) {
        return Ok(saved);
    }
    Err("Select a physical microphone in macOS before inviting Arco.".into())
}
fn restore_saved() -> Result<(), String> {
    if let Some(device) = hardware::find(VIRTUAL_UID) {
        if let Ok(data) = std::fs::read(journal()?) {
            if let Ok(value) = serde_json::from_slice::<serde_json::Value>(&data) {
                for (input, key) in [(true, "inputGain"), (false, "outputGain")] {
                    if hardware::gain(device, input) == Some(1.0) {
                        if let Some(gain) = value[key].as_f64() {
                            hardware::set_gain(device, input, gain as f32);
                        }
                    }
                }
            }
        }
    }
    if hardware::uid(hardware::default_input()?)? == VIRTUAL_UID {
        let saved = saved_uid().and_then(|u| hardware::find(&u));
        let target = saved
            .or_else(|| {
                hardware::devices()
                    .into_iter()
                    .find(|id| hardware::physical(*id))
            })
            .ok_or("Reconnect a physical microphone to restore meeting audio.")?;
        hardware::set_default(target)?;
    }
    if journal()?.exists() {
        std::fs::remove_file(journal()?).map_err(|e| e.to_string())?;
    }
    Ok(())
}
pub fn recover_stale() -> Result<(), String> {
    hardware::keep_alerts_on_speakers();
    if !journal()?.exists() {
        return Ok(());
    }
    let Ok(_lock) = lock() else { return Ok(()) };
    restore_saved()
}

pub struct MeetingRoute {
    _lock: File,
    original: String,
}
impl MeetingRoute {
    pub fn connect() -> Result<Self, String> {
        let held = lock()?;
        if journal()?.exists() {
            restore_saved()?;
        }
        let current = hardware::default_input()?;
        let original = hardware::uid(current)?;
        if !hardware::physical(current) {
            return Err("A physical default microphone is required.".into());
        }
        let target =
            hardware::find(VIRTUAL_UID).ok_or("Meeting audio component is not available")?;
        let tmp = journal()?.with_extension("tmp");
        use std::io::Write;
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)
            .map_err(|e| e.to_string())?;
        file.write_all(json!({"originalUID":original,"inputGain":hardware::gain(target,true),"outputGain":hardware::gain(target,false)}).to_string().as_bytes())
            .map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        std::fs::rename(tmp, journal()?).map_err(|e| e.to_string())?;
        let route = Self {
            _lock: held,
            original,
        };
        hardware::keep_alerts_on_speakers();
        hardware::set_gain(target, true, 1.0);
        hardware::set_gain(target, false, 1.0);
        hardware::set_default(target)?;
        Ok(route)
    }
    pub fn connected(&self) -> bool {
        hardware::find(&self.original).is_some()
            && hardware::default_input().and_then(hardware::uid).as_deref() == Ok(VIRTUAL_UID)
    }
}
impl Drop for MeetingRoute {
    fn drop(&mut self) {
        if let Err(e) = restore_saved() {
            eprintln!("Meeting audio restore: {e}")
        }
    }
}

pub fn available() -> bool {
    hardware::find(VIRTUAL_UID).is_some()
}
