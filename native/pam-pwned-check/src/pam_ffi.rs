use core::ffi::{c_char, c_int, c_void};
#[cfg(target_os = "linux")]
use std::ffi::CStr;

use zeroize::Zeroizing;

use crate::checker::run_checker;
use crate::config::parse_module_config_from_argv;
use crate::events::{
    emit_config, emit_log_event, emit_result, map_checker_outcome, rejection_message,
    ModuleDecision,
};

pub const PWNED_REJECTION_MESSAGE: &str =
    "This password appears in a known breach corpus. Choose a different password.";
pub const CHECK_FAILURE_MESSAGE: &str =
    "Password breach check failed. Try again later or contact your administrator.";

pub(crate) const PAM_SUCCESS: c_int = 0;
pub(crate) const PAM_IGNORE: c_int = 25;
pub(crate) const PAM_AUTHTOK_ERR: c_int = 20;
#[allow(dead_code)]
const PAM_CONV: c_int = 5;
#[allow(dead_code)]
const PAM_AUTHTOK: c_int = 6;
pub(crate) const PAM_PRELIM_CHECK: c_int = 0x4000;
pub(crate) const PAM_UPDATE_AUTHTOK: c_int = 0x2000;
#[allow(dead_code)]
const PAM_ERROR_MSG: c_int = 3;

#[repr(C)]
pub struct PamHandle {
    _private: [u8; 0],
}
#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}
#[repr(C)]
struct PamResponse {
    resp: *mut c_char,
    resp_retcode: c_int,
}

#[allow(dead_code)]
#[repr(C)]
struct PamConv {
    conv: Option<
        unsafe extern "C" fn(
            c_int,
            *mut *const PamMessage,
            *mut *mut PamResponse,
            *mut c_void,
        ) -> c_int,
    >,
    appdata_ptr: *mut c_void,
}

#[cfg(target_os = "linux")]
#[link(name = "pam")]
// Rust 2021 extern syntax is intentional until the distro MSRV/edition pin changes.
extern "C" {
    fn pam_get_item(pamh: *const PamHandle, item_type: c_int, item: *mut *const c_void) -> c_int;
    fn free(ptr: *mut c_void);
}

pub fn pam_return_for_decision(decision: ModuleDecision) -> c_int {
    match decision {
        ModuleDecision::Allow => PAM_SUCCESS,
        ModuleDecision::Reject { .. } => PAM_AUTHTOK_ERR,
    }
}

#[cfg(target_os = "linux")]
unsafe fn get_pam_item(pamh: *mut PamHandle, item_type: c_int) -> Result<*const c_void, c_int> {
    let mut item: *const c_void = std::ptr::null();
    let rc = unsafe { pam_get_item(pamh, item_type, &mut item) };
    if rc != PAM_SUCCESS {
        return Err(rc);
    }
    Ok(item)
}

#[cfg(target_os = "linux")]
unsafe fn get_authtok(pamh: *mut PamHandle) -> Result<Zeroizing<Vec<u8>>, c_int> {
    let item = unsafe { get_pam_item(pamh, PAM_AUTHTOK)? };
    if item.is_null() {
        return Err(PAM_AUTHTOK_ERR);
    }
    let token = unsafe { CStr::from_ptr(item.cast::<c_char>()) };
    let token_bytes = token.to_bytes();
    let mut candidate = Zeroizing::new(Vec::with_capacity(token_bytes.len()));
    candidate.extend_from_slice(token_bytes);
    Ok(candidate)
}

#[cfg(not(target_os = "linux"))]
unsafe fn get_authtok(_pamh: *mut PamHandle) -> Result<Zeroizing<Vec<u8>>, c_int> {
    Err(PAM_IGNORE)
}

#[cfg(target_os = "linux")]
unsafe fn send_pam_error(pamh: *mut PamHandle, message: &str) {
    let conv_item = match unsafe { get_pam_item(pamh, PAM_CONV) } {
        Ok(item) if !item.is_null() => item,
        _ => return,
    };
    let conv = unsafe { &*(conv_item.cast::<PamConv>()) };
    let Some(callback) = conv.conv else {
        return;
    };
    let Ok(c_message) = std::ffi::CString::new(message) else {
        return;
    };
    let pam_message = PamMessage {
        msg_style: PAM_ERROR_MSG,
        msg: c_message.as_ptr(),
    };
    let mut message_ptr: *const PamMessage = &pam_message;
    let mut response_ptr: *mut PamResponse = std::ptr::null_mut();
    let _ = unsafe { callback(1, &mut message_ptr, &mut response_ptr, conv.appdata_ptr) };
    if !response_ptr.is_null() {
        unsafe { free(response_ptr.cast::<c_void>()) };
    }
}

#[cfg(not(target_os = "linux"))]
unsafe fn send_pam_error(_pamh: *mut PamHandle, _message: &str) {}

#[no_mangle]
pub extern "C" fn pam_sm_authenticate(
    _pamh: *mut PamHandle,
    _flags: c_int,
    _argc: c_int,
    _argv: *const *const c_char,
) -> c_int {
    PAM_IGNORE
}

#[no_mangle]
pub extern "C" fn pam_sm_setcred(
    _pamh: *mut PamHandle,
    _flags: c_int,
    _argc: c_int,
    _argv: *const *const c_char,
) -> c_int {
    PAM_IGNORE
}

#[no_mangle]
pub extern "C" fn pam_sm_acct_mgmt(
    _pamh: *mut PamHandle,
    _flags: c_int,
    _argc: c_int,
    _argv: *const *const c_char,
) -> c_int {
    PAM_IGNORE
}

#[no_mangle]
pub extern "C" fn pam_sm_open_session(
    _pamh: *mut PamHandle,
    _flags: c_int,
    _argc: c_int,
    _argv: *const *const c_char,
) -> c_int {
    PAM_IGNORE
}

#[no_mangle]
pub extern "C" fn pam_sm_close_session(
    _pamh: *mut PamHandle,
    _flags: c_int,
    _argc: c_int,
    _argv: *const *const c_char,
) -> c_int {
    PAM_IGNORE
}

#[no_mangle]
pub extern "C" fn pam_sm_chauthtok(
    pamh: *mut PamHandle,
    flags: c_int,
    argc: c_int,
    argv: *const *const c_char,
) -> c_int {
    if flags & PAM_PRELIM_CHECK != 0 {
        return PAM_SUCCESS;
    }

    if flags & PAM_UPDATE_AUTHTOK != 0 {
        let config = match unsafe { parse_module_config_from_argv(argc, argv) } {
            Ok(config) => config,
            Err(_) => {
                unsafe { send_pam_error(pamh, CHECK_FAILURE_MESSAGE) };
                emit_log_event("event=pam_module_failure reason=module_config");
                return PAM_AUTHTOK_ERR;
            }
        };
        emit_config(&config);

        let candidate = match unsafe { get_authtok(pamh) } {
            Ok(candidate) if !candidate.is_empty() => candidate,
            _ => {
                unsafe { send_pam_error(pamh, CHECK_FAILURE_MESSAGE) };
                emit_log_event("event=pam_module_failure reason=missing_authtok");
                return PAM_AUTHTOK_ERR;
            }
        };

        let checker = run_checker(&config, &candidate);
        let decision = map_checker_outcome(checker.outcome, config.dry_run);
        emit_result(checker.outcome, decision, &config);

        if let ModuleDecision::Reject { reason } = decision {
            unsafe { send_pam_error(pamh, rejection_message(reason)) };
        }

        return pam_return_for_decision(decision);
    }

    PAM_IGNORE
}
