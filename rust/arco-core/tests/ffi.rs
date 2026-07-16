use arco_core::ffi::{
    arco_runtime_create, arco_runtime_destroy, arco_runtime_dispatch, arco_string_free,
    ArcoEventCallback,
};
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use tempfile::TempDir;

unsafe fn take_json(pointer: *mut std::ffi::c_char) -> Value {
    assert!(!pointer.is_null());
    let value: Value = serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap();
    arco_string_free(pointer);
    value
}

#[test]
fn ffi_runtime_dispatches_stable_json_and_reports_errors_without_panicking() {
    let root = TempDir::new().unwrap();
    let config = CString::new(
        json!({
            "appDataDir": root.path().join("app-data"),
            "nativeDir": root.path().join("native"),
            "homeDir": root.path().join("home")
        })
        .to_string(),
    )
    .unwrap();
    let runtime = unsafe {
        arco_runtime_create(
            config.as_ptr(),
            None::<ArcoEventCallback>,
            std::ptr::null_mut(),
        )
    };
    assert!(!runtime.is_null());

    let command = CString::new("capture_status").unwrap();
    let args = CString::new("{}").unwrap();
    let response = unsafe {
        take_json(arco_runtime_dispatch(
            runtime,
            command.as_ptr(),
            args.as_ptr(),
        ))
    };
    assert_eq!(response["ok"], true);
    assert_eq!(response["result"]["phase"], "idle");

    let malformed = CString::new("{").unwrap();
    let response = unsafe {
        take_json(arco_runtime_dispatch(
            runtime,
            command.as_ptr(),
            malformed.as_ptr(),
        ))
    };
    assert_eq!(response["ok"], false);
    assert!(response["error"]
        .as_str()
        .unwrap()
        .contains("invalid backend arguments JSON"));

    unsafe { arco_runtime_destroy(runtime) };
}
