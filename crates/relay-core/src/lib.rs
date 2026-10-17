mod database;
mod files;
pub mod model;
pub mod workflow;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    path::Path,
    sync::Mutex,
};
use workflow::Core;
fn owned(value: Value) -> *mut c_char {
    CString::new(value.to_string()).unwrap().into_raw()
}
fn response(action: impl FnOnce() -> Result<Value, String>) -> *mut c_char {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(action)) {
        Ok(Ok(value)) => owned(json!({"ok":true,"value":value})),
        Ok(Err(error)) => owned(json!({"ok":false,"error":error})),
        Err(_) => owned(
            json!({"ok":false,"error":"Unexpected core panic; inspect the journal before retrying"}),
        ),
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn relay_core_api_version() -> u32 {
    1
}
/// # Safety
/// `path` is valid NUL-terminated UTF-8 for this call; `error` is writable if nonnull.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_core_open(
    path: *const c_char,
    error: *mut *mut c_char,
) -> *mut c_void {
    let result = std::panic::catch_unwind(|| {
        if path.is_null() {
            return Err("Missing database path".into());
        }
        let path = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|e| e.to_string())?;
        Core::open(Path::new(path))
    });
    match result {
        Ok(Ok(core)) => Box::into_raw(Box::new(Mutex::new(core))).cast(),
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                _ => "Cannot initialize RELAY".into(),
            };
            if !error.is_null() {
                unsafe {
                    *error = owned(json!({"ok":false,"error":message}));
                }
            }
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// `handle` is live and not concurrently closed, `request` is NUL-terminated UTF-8.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_core_command(
    handle: *mut c_void,
    request: *const c_char,
) -> *mut c_char {
    response(|| {
        let core = unsafe { handle.cast::<Mutex<Core>>().as_ref() }.ok_or("Missing core handle")?;
        if request.is_null() {
            return Err("Missing request".into());
        }
        let value = serde_json::from_str(
            unsafe { CStr::from_ptr(request) }
                .to_str()
                .map_err(|e| e.to_string())?,
        )
        .map_err(|e| e.to_string())?;
        core.lock()
            .map_err(|_| "The core needs to be reopened after a failed operation")?
            .command(value)
    })
}
/// # Safety
/// Close a live handle exactly once, with no concurrent calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_core_close(handle: *mut c_void) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle.cast::<Mutex<Core>>()) });
    }
}
/// # Safety
/// Free a string returned by this library exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn relay_core_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
