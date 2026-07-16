use crate::controller::{Controller, EventSink};
use crate::paths::{home_dir, AppPaths};
use serde::Deserialize;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::ffi::{c_char, c_void, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

pub type ArcoEventCallback =
    unsafe extern "C" fn(name: *const c_char, payload_json: *const c_char, context: *mut c_void);

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

struct CallbackEventSink {
    callback: Option<ArcoEventCallback>,
    context: usize,
}

impl EventSink for CallbackEventSink {
    fn emit(&self, name: &str, payload: Value) {
        let Some(callback) = self.callback else {
            return;
        };
        let Ok(name) = CString::new(name) else {
            return;
        };
        let Ok(payload) = CString::new(payload.to_string()) else {
            return;
        };
        // SAFETY: The embedding Swift app owns the callback and context for the
        // full runtime lifetime. Swift dispatches UI work back to its main actor.
        unsafe { callback(name.as_ptr(), payload.as_ptr(), self.context as *mut c_void) };
    }
}

pub struct ArcoRuntime {
    controller: Controller,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeConfig {
    #[serde(default)]
    resource_dir: Option<PathBuf>,
    #[serde(default)]
    app_data_dir: Option<PathBuf>,
    #[serde(default)]
    native_dir: Option<PathBuf>,
    #[serde(default)]
    home_dir: Option<PathBuf>,
}

#[no_mangle]
/// Creates one Rust backend runtime for an embedding native application.
///
/// # Safety
///
/// `config_json` must point to a valid, null-terminated UTF-8 string for the
/// duration of this call. When supplied, `callback` must remain callable and
/// `context` must remain valid until the returned runtime is destroyed.
pub unsafe extern "C" fn arco_runtime_create(
    config_json: *const c_char,
    callback: Option<ArcoEventCallback>,
    context: *mut c_void,
) -> *mut ArcoRuntime {
    clear_last_error();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let config: RuntimeConfig =
            serde_json::from_str(read_string(config_json, "runtime config")?)
                .map_err(|error| format!("invalid runtime config JSON: {error}"))?;
        let home = match config.home_dir {
            Some(home) => home,
            None => home_dir()?,
        };
        let app_data = config.app_data_dir.unwrap_or_else(|| {
            home.join("Library")
                .join("Application Support")
                .join("Arco")
        });
        let native_dir = config
            .native_dir
            .or_else(|| {
                config
                    .resource_dir
                    .map(|directory| directory.join("native"))
            })
            .unwrap_or_else(|| {
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .parent()
                    .and_then(std::path::Path::parent)
                    .unwrap_or_else(|| std::path::Path::new("."))
                    .join("native")
            });
        let paths = AppPaths {
            transcripts: app_data.join("transcripts"),
            notes: app_data.join("notes"),
            legacy_transcripts: home.join(".claude").join("meeting-transcripts"),
            home,
            app_data,
            native_dir,
        };
        let events = Arc::new(CallbackEventSink {
            callback,
            context: context as usize,
        });
        Controller::new(paths, events)
            .map(|controller| Box::into_raw(Box::new(ArcoRuntime { controller })))
    }));
    match result {
        Ok(Ok(runtime)) => runtime,
        Ok(Err(error)) => {
            set_last_error(error);
            ptr::null_mut()
        }
        Err(_) => {
            set_last_error("Arco backend panicked while creating the runtime".into());
            ptr::null_mut()
        }
    }
}

#[no_mangle]
/// Dispatches one JSON command through an existing runtime.
///
/// # Safety
///
/// `runtime` must be a live pointer returned by `arco_runtime_create`.
/// `command` and `args_json` must be valid null-terminated UTF-8 strings for
/// the duration of this call. The returned string must be released exactly
/// once with `arco_string_free`.
pub unsafe extern "C" fn arco_runtime_dispatch(
    runtime: *mut ArcoRuntime,
    command: *const c_char,
    args_json: *const c_char,
) -> *mut c_char {
    let response = catch_unwind(AssertUnwindSafe(|| -> Result<Value, String> {
        let runtime = runtime
            .as_ref()
            .ok_or_else(|| "Arco backend runtime is not available".to_string())?;
        let command = read_string(command, "command")?;
        let args: Value = serde_json::from_str(read_string(args_json, "arguments")?)
            .map_err(|error| format!("invalid backend arguments JSON: {error}"))?;
        runtime.controller.dispatch(command, args)
    }));
    let envelope = match response {
        Ok(Ok(result)) => json!({ "ok": true, "result": result }),
        Ok(Err(error)) => json!({ "ok": false, "error": error }),
        Err(_) => json!({
            "ok": false,
            "error": "Arco backend panicked while dispatching the command"
        }),
    };
    into_c_string(envelope.to_string())
}

#[no_mangle]
/// Destroys a runtime created by `arco_runtime_create`.
///
/// # Safety
///
/// `runtime` must be null or a live runtime pointer that has not already been
/// destroyed. No dispatch may still be using it.
pub unsafe extern "C" fn arco_runtime_destroy(runtime: *mut ArcoRuntime) {
    if !runtime.is_null() {
        // SAFETY: The pointer was returned by Box::into_raw in create and the
        // API requires exactly one destroy call after all requests finish.
        drop(Box::from_raw(runtime));
    }
}

#[no_mangle]
/// Releases a string returned by `arco_runtime_dispatch`.
///
/// # Safety
///
/// `value` must be null or a pointer returned by this library that has not
/// already been freed.
pub unsafe extern "C" fn arco_string_free(value: *mut c_char) {
    if !value.is_null() {
        // SAFETY: All returned strings are allocated by CString::into_raw.
        drop(CString::from_raw(value));
    }
}

#[no_mangle]
pub extern "C" fn arco_last_error_message() -> *const c_char {
    LAST_ERROR.with(|slot| {
        slot.borrow()
            .as_ref()
            .map_or(ptr::null(), |message| message.as_ptr())
    })
}

fn read_string<'a>(pointer: *const c_char, field: &str) -> Result<&'a str, String> {
    if pointer.is_null() {
        return Err(format!("{field} pointer is null"));
    }
    // SAFETY: The C ABI requires a valid null-terminated string for the call.
    unsafe { CStr::from_ptr(pointer) }
        .to_str()
        .map_err(|error| format!("{field} is not UTF-8: {error}"))
}

fn into_c_string(value: String) -> *mut c_char {
    CString::new(value)
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"invalid response\"}").unwrap())
        .into_raw()
}

fn set_last_error(error: String) {
    LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = CString::new(error).ok();
    });
}

fn clear_last_error() {
    LAST_ERROR.with(|slot| *slot.borrow_mut() = None);
}
