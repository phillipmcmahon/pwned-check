#![deny(unsafe_op_in_unsafe_fn)]

use core::ffi::{c_char, c_int, c_void};
use std::ffi::CStr;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
#[cfg(unix)]
use std::{io, os::unix::process::CommandExt};

const DEFAULT_CHECKER: &str = "/usr/local/bin/pwned-check";
const DEFAULT_TIMEOUT_SECONDS: u64 = 3;
const CHECKER_STDERR_LIMIT: usize = 512;
const CHECKER_TIMEOUT_GRACE: Duration = Duration::from_millis(200);

pub const PWNED_REJECTION_MESSAGE: &str =
    "This password appears in a known breach corpus. Choose a different password.";
pub const CHECK_FAILURE_MESSAGE: &str =
    "Password breach check failed. Try again later or contact your administrator.";

const PAM_SUCCESS: c_int = 0;
const PAM_IGNORE: c_int = 25;
const PAM_AUTHTOK_ERR: c_int = 20;
#[allow(dead_code)]
const PAM_CONV: c_int = 5;
#[allow(dead_code)]
const PAM_AUTHTOK: c_int = 6;
const PAM_PRELIM_CHECK: c_int = 0x4000;
const PAM_UPDATE_AUTHTOK: c_int = 0x2000;
#[allow(dead_code)]
const PAM_ERROR_MSG: c_int = 3;

#[repr(C)]
pub struct PamHandle {
    _private: [u8; 0],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleConfig {
    pub checker: String,
    pub timeout_seconds: u64,
    pub fail_policy: FailPolicy,
    pub dry_run: bool,
    pub debug: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailPolicy {
    Inherit,
    FailOpen,
    FailClosed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigError {
    EmptyChecker,
    InvalidTimeout,
    ConflictingFailPolicy,
    InvalidUtf8,
    NullArgument,
    UnknownArgument(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckerOutcome {
    Clean,
    Pwned,
    ConfigError,
    ProviderFailure,
    Timeout,
    ExecFailure,
    UnexpectedExit(i32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModuleDecision {
    Allow,
    Reject { reason: RejectReason },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    Pwned,
    CheckerConfig,
    CheckerProvider,
    Timeout,
    Exec,
    CheckerExit,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckerRun {
    pub outcome: CheckerOutcome,
    pub stderr: String,
}

#[allow(dead_code)]
#[repr(C)]
struct PamMessage {
    msg_style: c_int,
    msg: *const c_char,
}

#[allow(dead_code)]
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
extern "C" {
    fn pam_get_item(pamh: *const PamHandle, item_type: c_int, item: *mut *const c_void) -> c_int;
    fn free(ptr: *mut c_void);
}

#[cfg(unix)]
extern "C" {
    fn close(fd: c_int) -> c_int;
    fn kill(pid: c_int, sig: c_int) -> c_int;
    fn setpgid(pid: c_int, pgid: c_int) -> c_int;
    fn sysconf(name: c_int) -> isize;
}

#[cfg(target_os = "linux")]
extern "C" {
    fn openlog(ident: *const c_char, option: c_int, facility: c_int);
    fn syslog(priority: c_int, format: *const c_char, ...);
}

#[cfg(unix)]
const SIGTERM: c_int = 15;
#[cfg(unix)]
const SIGKILL: c_int = 9;
#[cfg(unix)]
const SC_OPEN_MAX: c_int = 5;
#[cfg(target_os = "linux")]
const LOG_PID: c_int = 0x01;
#[cfg(target_os = "linux")]
const LOG_NDELAY: c_int = 0x08;
#[cfg(target_os = "linux")]
const LOG_INFO: c_int = 6;
#[cfg(target_os = "linux")]
const LOG_AUTHPRIV: c_int = 10 << 3;
#[cfg(target_os = "linux")]
const SYSLOG_IDENT: &[u8] = b"pwned-check\0";
#[cfg(target_os = "linux")]
const SYSLOG_FORMAT: &[u8] = b"%s\0";

impl Default for ModuleConfig {
    fn default() -> Self {
        Self {
            checker: DEFAULT_CHECKER.to_string(),
            timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
            fail_policy: FailPolicy::Inherit,
            dry_run: false,
            debug: false,
        }
    }
}

pub fn parse_module_config(args: &[&str]) -> Result<ModuleConfig, ConfigError> {
    let mut config = ModuleConfig::default();
    let mut saw_fail_open = false;
    let mut saw_fail_closed = false;

    for arg in args {
        if let Some(value) = arg.strip_prefix("checker=") {
            if value.is_empty() {
                return Err(ConfigError::EmptyChecker);
            }
            config.checker = value.to_string();
            continue;
        }

        if let Some(value) = arg.strip_prefix("timeout=") {
            let seconds = value
                .parse::<u64>()
                .ok()
                .filter(|seconds| *seconds > 0)
                .ok_or(ConfigError::InvalidTimeout)?;
            config.timeout_seconds = seconds;
            continue;
        }

        match *arg {
            "fail_open" => {
                saw_fail_open = true;
                config.fail_policy = FailPolicy::FailOpen;
            }
            "fail_closed" => {
                saw_fail_closed = true;
                config.fail_policy = FailPolicy::FailClosed;
            }
            "dry_run" => config.dry_run = true,
            "debug" => config.debug = true,
            other => return Err(ConfigError::UnknownArgument(other.to_string())),
        }
    }

    if saw_fail_open && saw_fail_closed {
        return Err(ConfigError::ConflictingFailPolicy);
    }

    Ok(config)
}

unsafe fn parse_module_config_from_argv(
    argc: c_int,
    argv: *const *const c_char,
) -> Result<ModuleConfig, ConfigError> {
    if argc < 0 {
        return Err(ConfigError::UnknownArgument("negative argc".to_string()));
    }
    if argc > 0 && argv.is_null() {
        return Err(ConfigError::NullArgument);
    }

    let mut args = Vec::new();
    for index in 0..argc as isize {
        let ptr = unsafe { *argv.offset(index) };
        if ptr.is_null() {
            return Err(ConfigError::NullArgument);
        }
        let value = unsafe { CStr::from_ptr(ptr) }
            .to_str()
            .map_err(|_| ConfigError::InvalidUtf8)?;
        args.push(value);
    }

    parse_module_config(&args)
}

pub fn map_checker_outcome(outcome: CheckerOutcome, dry_run: bool) -> ModuleDecision {
    let decision = match outcome {
        CheckerOutcome::Clean => ModuleDecision::Allow,
        CheckerOutcome::Pwned => ModuleDecision::Reject {
            reason: RejectReason::Pwned,
        },
        CheckerOutcome::ConfigError => ModuleDecision::Reject {
            reason: RejectReason::CheckerConfig,
        },
        CheckerOutcome::ProviderFailure => ModuleDecision::Reject {
            reason: RejectReason::CheckerProvider,
        },
        CheckerOutcome::Timeout => ModuleDecision::Reject {
            reason: RejectReason::Timeout,
        },
        CheckerOutcome::ExecFailure => ModuleDecision::Reject {
            reason: RejectReason::Exec,
        },
        CheckerOutcome::UnexpectedExit(_) => ModuleDecision::Reject {
            reason: RejectReason::CheckerExit,
        },
    };

    if dry_run {
        ModuleDecision::Allow
    } else {
        decision
    }
}

pub fn pam_return_for_decision(decision: ModuleDecision) -> c_int {
    match decision {
        ModuleDecision::Allow => PAM_SUCCESS,
        ModuleDecision::Reject { .. } => PAM_AUTHTOK_ERR,
    }
}

pub fn run_checker(config: &ModuleConfig, candidate: &[u8]) -> CheckerRun {
    let stderr_path = temp_stderr_path();
    let stderr_file = match OpenOptions::new()
        .create_new(true)
        .read(true)
        .write(true)
        .open(&stderr_path)
    {
        Ok(file) => file,
        Err(_) => {
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            }
        }
    };

    let stderr_for_child = match stderr_file.try_clone() {
        Ok(file) => file,
        Err(_) => {
            let _ = fs::remove_file(&stderr_path);
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            };
        }
    };

    let mut command = Command::new(&config.checker);
    command
        .arg("--stdin")
        .env_clear()
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::from(stderr_for_child));

    configure_child_process(&mut command);

    match config.fail_policy {
        FailPolicy::Inherit => {}
        FailPolicy::FailOpen => {
            command.env("PWNED_CHECK_FAIL_CLOSED", "false");
        }
        FailPolicy::FailClosed => {
            command.env("PWNED_CHECK_FAIL_CLOSED", "true");
        }
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => {
            let _ = fs::remove_file(&stderr_path);
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr: String::new(),
            };
        }
    };

    if let Some(mut stdin) = child.stdin.take() {
        if stdin.write_all(candidate).is_err() {
            let _ = child.kill();
            let _ = child.wait();
            let stderr = read_bounded_stderr(&stderr_path);
            let _ = fs::remove_file(&stderr_path);
            return CheckerRun {
                outcome: CheckerOutcome::ExecFailure,
                stderr,
            };
        }
    }

    let deadline = Instant::now() + Duration::from_secs(config.timeout_seconds);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) => {
                if Instant::now() >= deadline {
                    terminate_child(&mut child, CHECKER_TIMEOUT_GRACE);
                    break None;
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => break Some(exit_status_from_error()),
        }
    };

    let stderr = read_bounded_stderr(&stderr_path);
    let _ = fs::remove_file(&stderr_path);

    let outcome = match status {
        None => CheckerOutcome::Timeout,
        Some(status) => match status.code() {
            Some(0) => CheckerOutcome::Clean,
            Some(1) => CheckerOutcome::Pwned,
            Some(2) => CheckerOutcome::ConfigError,
            Some(3) => CheckerOutcome::ProviderFailure,
            Some(code) => CheckerOutcome::UnexpectedExit(code),
            None => CheckerOutcome::UnexpectedExit(-1),
        },
    };

    CheckerRun { outcome, stderr }
}

#[cfg(unix)]
fn configure_child_process(command: &mut Command) {
    let max_fd = open_max();
    unsafe {
        command.pre_exec(move || {
            if setpgid(0, 0) != 0 {
                return Err(io::Error::last_os_error());
            }

            for fd in 3..max_fd {
                let _ = close(fd);
            }

            Ok(())
        });
    }
}

#[cfg(not(unix))]
fn configure_child_process(_command: &mut Command) {}

#[cfg(unix)]
fn open_max() -> c_int {
    let value = unsafe { sysconf(SC_OPEN_MAX) };
    if value > 3 && value < 65_536 {
        value as c_int
    } else {
        1024
    }
}

#[cfg(unix)]
fn terminate_child(child: &mut std::process::Child, grace: Duration) {
    let pid = child.id() as c_int;
    let process_group = -pid;
    let _ = unsafe { kill(process_group, SIGTERM) };

    let deadline = Instant::now() + grace;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) => {
                if Instant::now() >= deadline {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(_) => return,
        }
    }

    let _ = unsafe { kill(process_group, SIGKILL) };
    let _ = child.wait();
}

#[cfg(not(unix))]
fn terminate_child(child: &mut std::process::Child, _grace: Duration) {
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(unix)]
fn exit_status_from_error() -> std::process::ExitStatus {
    use std::os::unix::process::ExitStatusExt;
    std::process::ExitStatus::from_raw(255 << 8)
}

#[cfg(not(unix))]
fn exit_status_from_error() -> std::process::ExitStatus {
    panic!("unsupported non-Unix native PAM target")
}

fn temp_stderr_path() -> std::path::PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| Duration::from_secs(0))
        .as_nanos();
    std::env::temp_dir().join(format!(
        "pam-pwned-check-stderr-{}-{nanos}",
        std::process::id()
    ))
}

fn read_bounded_stderr(path: &std::path::Path) -> String {
    let file = OpenOptions::new().read(true).open(path);
    let mut file = match file {
        Ok(file) => file,
        Err(_) => return String::new(),
    };
    let mut buffer = vec![0; CHECKER_STDERR_LIMIT + 1];
    let read = match file.read(&mut buffer) {
        Ok(read) => read,
        Err(_) => return String::new(),
    };
    buffer.truncate(read.min(CHECKER_STDERR_LIMIT));
    String::from_utf8_lossy(&buffer).trim().to_string()
}

fn rejection_message(reason: RejectReason) -> &'static str {
    match reason {
        RejectReason::Pwned => PWNED_REJECTION_MESSAGE,
        RejectReason::CheckerConfig
        | RejectReason::CheckerProvider
        | RejectReason::Timeout
        | RejectReason::Exec
        | RejectReason::CheckerExit => CHECK_FAILURE_MESSAGE,
    }
}

fn emit_config(config: &ModuleConfig) {
    if config.debug {
        emit_log_event(&format_config_event(config));
    }
}

fn emit_result(outcome: CheckerOutcome, decision: ModuleDecision, config: &ModuleConfig) {
    if let Some(event) = format_failure_event(outcome, config.timeout_seconds) {
        emit_log_event(&event);
    }

    emit_log_event(&format_result_event(outcome, decision, config.dry_run));
}

fn format_result_event(outcome: CheckerOutcome, decision: ModuleDecision, dry_run: bool) -> String {
    if dry_run {
        return match outcome {
            CheckerOutcome::Clean => {
                "event=pam_module_result result=allow mode=dry_run".to_string()
            }
            _ => format!(
                "event=pam_module_result result=allow mode=dry_run would=reject reason={}",
                reason_name(reject_reason_for_outcome(outcome))
            ),
        };
    }

    match decision {
        ModuleDecision::Allow => "event=pam_module_result result=allow".to_string(),
        ModuleDecision::Reject { reason } => {
            format!(
                "event=pam_module_result result=reject reason={}",
                reason_name(reason)
            )
        }
    }
}

fn format_failure_event(outcome: CheckerOutcome, timeout_seconds: u64) -> Option<String> {
    match outcome {
        CheckerOutcome::Clean | CheckerOutcome::Pwned => None,
        CheckerOutcome::ConfigError => {
            Some("event=pam_module_failure reason=checker_config code=2".to_string())
        }
        CheckerOutcome::ProviderFailure => {
            Some("event=pam_module_failure reason=checker_provider code=3".to_string())
        }
        CheckerOutcome::Timeout => Some(format!(
            "event=pam_module_failure reason=timeout timeout={}s",
            timeout_seconds
        )),
        CheckerOutcome::ExecFailure => Some("event=pam_module_failure reason=exec".to_string()),
        CheckerOutcome::UnexpectedExit(code) => Some(format!(
            "event=pam_module_failure reason=checker_exit code={code}"
        )),
    }
}

fn format_config_event(config: &ModuleConfig) -> String {
    format!(
        "event=pam_module_config timeout={}s fail_policy={} dry_run={}",
        config.timeout_seconds,
        fail_policy_name(config.fail_policy),
        config.dry_run
    )
}

fn emit_log_event(event: &str) {
    #[cfg(target_os = "linux")]
    {
        if let Ok(c_event) = std::ffi::CString::new(event) {
            unsafe {
                openlog(
                    SYSLOG_IDENT.as_ptr().cast::<c_char>(),
                    LOG_PID | LOG_NDELAY,
                    LOG_AUTHPRIV,
                );
                syslog(
                    LOG_INFO,
                    SYSLOG_FORMAT.as_ptr().cast::<c_char>(),
                    c_event.as_ptr(),
                );
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    eprintln!("{event}");
}

fn fail_policy_name(policy: FailPolicy) -> &'static str {
    match policy {
        FailPolicy::Inherit => "inherit",
        FailPolicy::FailOpen => "fail_open",
        FailPolicy::FailClosed => "fail_closed",
    }
}

fn reject_reason_for_outcome(outcome: CheckerOutcome) -> RejectReason {
    match outcome {
        CheckerOutcome::Clean => RejectReason::CheckerExit,
        CheckerOutcome::Pwned => RejectReason::Pwned,
        CheckerOutcome::ConfigError => RejectReason::CheckerConfig,
        CheckerOutcome::ProviderFailure => RejectReason::CheckerProvider,
        CheckerOutcome::Timeout => RejectReason::Timeout,
        CheckerOutcome::ExecFailure => RejectReason::Exec,
        CheckerOutcome::UnexpectedExit(_) => RejectReason::CheckerExit,
    }
}

fn reason_name(reason: RejectReason) -> &'static str {
    match reason {
        RejectReason::Pwned => "pwned",
        RejectReason::CheckerConfig => "checker_config",
        RejectReason::CheckerProvider => "checker_provider",
        RejectReason::Timeout => "timeout",
        RejectReason::Exec => "exec",
        RejectReason::CheckerExit => "checker_exit",
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
unsafe fn get_authtok(pamh: *mut PamHandle) -> Result<Vec<u8>, c_int> {
    let item = unsafe { get_pam_item(pamh, PAM_AUTHTOK)? };
    if item.is_null() {
        return Err(PAM_AUTHTOK_ERR);
    }
    let token = unsafe { CStr::from_ptr(item.cast::<c_char>()) };
    Ok(token.to_bytes().to_vec())
}

#[cfg(not(target_os = "linux"))]
unsafe fn get_authtok(_pamh: *mut PamHandle) -> Result<Vec<u8>, c_int> {
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

        let mut candidate = match unsafe { get_authtok(pamh) } {
            Ok(candidate) if !candidate.is_empty() => candidate,
            _ => {
                unsafe { send_pam_error(pamh, CHECK_FAILURE_MESSAGE) };
                emit_log_event("event=pam_module_failure reason=missing_authtok");
                return PAM_AUTHTOK_ERR;
            }
        };

        let checker = run_checker(&config, &candidate);
        candidate.fill(0);
        let decision = map_checker_outcome(checker.outcome, config.dry_run);
        emit_result(checker.outcome, decision, &config);

        if let ModuleDecision::Reject { reason } = decision {
            unsafe { send_pam_error(pamh, rejection_message(reason)) };
        }

        return pam_return_for_decision(decision);
    }

    PAM_IGNORE
}

#[allow(dead_code)]
type PamItem = *const c_void;

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::io::Write;
    use std::sync::{Mutex, MutexGuard};

    static CHECKER_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn parse_defaults() {
        assert_eq!(
            parse_module_config(&[]).unwrap(),
            ModuleConfig {
                checker: "/usr/local/bin/pwned-check".to_string(),
                timeout_seconds: 3,
                fail_policy: FailPolicy::Inherit,
                dry_run: false,
                debug: false,
            }
        );
    }

    #[test]
    fn parse_all_supported_arguments() {
        assert_eq!(
            parse_module_config(&[
                "checker=/opt/pwned-check",
                "timeout=9",
                "fail_closed",
                "dry_run",
                "debug"
            ])
            .unwrap(),
            ModuleConfig {
                checker: "/opt/pwned-check".to_string(),
                timeout_seconds: 9,
                fail_policy: FailPolicy::FailClosed,
                dry_run: true,
                debug: true,
            }
        );
    }

    #[test]
    fn parse_rejects_conflicting_fail_policy() {
        assert_eq!(
            parse_module_config(&["fail_open", "fail_closed"]),
            Err(ConfigError::ConflictingFailPolicy)
        );
    }

    #[test]
    fn parse_rejects_unknown_arguments() {
        assert_eq!(
            parse_module_config(&["fail_clsoed"]),
            Err(ConfigError::UnknownArgument("fail_clsoed".to_string()))
        );
    }

    #[test]
    fn parse_rejects_invalid_timeout() {
        assert_eq!(
            parse_module_config(&["timeout=0"]),
            Err(ConfigError::InvalidTimeout)
        );
        assert_eq!(
            parse_module_config(&["timeout=abc"]),
            Err(ConfigError::InvalidTimeout)
        );
    }

    #[test]
    fn parse_rejects_empty_checker() {
        assert_eq!(
            parse_module_config(&["checker="]),
            Err(ConfigError::EmptyChecker)
        );
    }

    #[test]
    fn parse_from_raw_argv() {
        let args = [
            CString::new("checker=/tmp/checker").unwrap(),
            CString::new("timeout=4").unwrap(),
            CString::new("fail_open").unwrap(),
        ];
        let raw = args.iter().map(|arg| arg.as_ptr()).collect::<Vec<_>>();
        let config = unsafe { parse_module_config_from_argv(raw.len() as c_int, raw.as_ptr()) }
            .expect("argv should parse");

        assert_eq!(config.checker, "/tmp/checker");
        assert_eq!(config.timeout_seconds, 4);
        assert_eq!(config.fail_policy, FailPolicy::FailOpen);
    }

    #[test]
    fn parse_from_raw_argv_rejects_null_argument() {
        let raw = [std::ptr::null()];
        assert_eq!(
            unsafe { parse_module_config_from_argv(raw.len() as c_int, raw.as_ptr()) },
            Err(ConfigError::NullArgument)
        );
    }

    #[test]
    fn parse_module_config_property_corpus_does_not_panic() {
        let corpus = [
            "",
            "checker=",
            "checker=/bin/true",
            "checker=/tmp/pwned check",
            "checker=/tmp/pwned-check\nnewline",
            "timeout=",
            "timeout=0",
            "timeout=1",
            "timeout=999999",
            "timeout=18446744073709551615",
            "timeout=18446744073709551616",
            "timeout=abc",
            "fail_open",
            "fail_closed",
            "dry_run",
            "debug",
            "min_count=1",
            "fail_open=1",
            "unknown",
            "checker=/bin/true\ttab",
        ];

        for first in corpus {
            assert!(
                std::panic::catch_unwind(|| parse_module_config(&[first])).is_ok(),
                "parser panicked for one arg: {first:?}"
            );
            for second in corpus {
                assert!(
                    std::panic::catch_unwind(|| parse_module_config(&[first, second])).is_ok(),
                    "parser panicked for two args: {first:?}, {second:?}"
                );
                for third in ["fail_open", "fail_closed", "dry_run", "debug", "timeout=2"] {
                    assert!(
                        std::panic::catch_unwind(|| {
                            parse_module_config(&[first, second, third])
                        })
                        .is_ok(),
                        "parser panicked for three args: {first:?}, {second:?}, {third:?}"
                    );
                }
            }
        }
    }

    #[test]
    fn pam_constants_match_linux_pam_headers() {
        assert_eq!(PAM_SUCCESS, 0);
        assert_eq!(PAM_AUTHTOK_ERR, 20);
        assert_eq!(PAM_IGNORE, 25);
        assert_eq!(PAM_UPDATE_AUTHTOK, 0x2000);
        assert_eq!(PAM_PRELIM_CHECK, 0x4000);
    }

    #[test]
    fn outcome_mapping_rejects_checker_failures() {
        let cases = [
            (CheckerOutcome::Pwned, RejectReason::Pwned),
            (CheckerOutcome::ConfigError, RejectReason::CheckerConfig),
            (
                CheckerOutcome::ProviderFailure,
                RejectReason::CheckerProvider,
            ),
            (CheckerOutcome::Timeout, RejectReason::Timeout),
            (CheckerOutcome::ExecFailure, RejectReason::Exec),
            (CheckerOutcome::UnexpectedExit(9), RejectReason::CheckerExit),
        ];

        for (outcome, reason) in cases {
            assert_eq!(
                map_checker_outcome(outcome, false),
                ModuleDecision::Reject { reason }
            );
        }
    }

    #[test]
    fn clean_outcome_allows() {
        assert_eq!(
            map_checker_outcome(CheckerOutcome::Clean, false),
            ModuleDecision::Allow
        );
        assert_eq!(
            pam_return_for_decision(map_checker_outcome(CheckerOutcome::Clean, false)),
            PAM_SUCCESS
        );
    }

    #[test]
    fn checker_runner_maps_exit_codes() {
        let _guard = checker_test_lock();
        let checker = fake_checker(
            r#"#!/bin/sh
/bin/cat >/dev/null
exit "$PWNED_CHECK_FAKE_EXIT"
"#,
        );
        let mut config = ModuleConfig {
            checker,
            ..ModuleConfig::default()
        };

        for (code, outcome) in [
            ("0", CheckerOutcome::Clean),
            ("1", CheckerOutcome::Pwned),
            ("2", CheckerOutcome::ConfigError),
            ("3", CheckerOutcome::ProviderFailure),
            ("9", CheckerOutcome::UnexpectedExit(9)),
        ] {
            config.checker = fake_checker(&format!(
                "#!/bin/sh\n/bin/cat >/dev/null\nPWNED_CHECK_FAKE_EXIT={code}\nexit \"$PWNED_CHECK_FAKE_EXIT\"\n"
            ));
            assert_eq!(run_checker(&config, b"candidate").outcome, outcome);
        }
    }

    #[test]
    fn checker_runner_passes_fail_policy() {
        let _guard = checker_test_lock();
        let checker = fake_checker(
            r#"#!/bin/sh
/bin/cat >/dev/null
if [ "${PWNED_CHECK_FAIL_CLOSED:-}" = "true" ]; then
  exit 3
fi
exit 0
"#,
        );
        let config = ModuleConfig {
            checker,
            fail_policy: FailPolicy::FailClosed,
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::ProviderFailure
        );
    }

    #[test]
    fn checker_runner_times_out() {
        let _guard = checker_test_lock();
        let checker = fake_checker("#!/bin/sh\n/bin/cat >/dev/null\n/bin/sleep 2\nexit 0\n");
        let config = ModuleConfig {
            checker,
            timeout_seconds: 1,
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::Timeout
        );
    }

    #[test]
    fn checker_runner_escalates_timeout_after_grace() {
        let _guard = checker_test_lock();
        let checker = fake_checker("#!/bin/sh\ntrap '' TERM\n/bin/cat >/dev/null\n/bin/sleep 30\n");
        let config = ModuleConfig {
            checker,
            timeout_seconds: 1,
            ..ModuleConfig::default()
        };
        let started = Instant::now();

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::Timeout
        );
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "timeout runner did not escalate promptly"
        );
    }

    #[test]
    fn checker_runner_uses_clean_environment() {
        let _guard = checker_test_lock();
        std::env::set_var("PWNED_CHECK_SHOULD_NOT_LEAK", "secret");
        let env_path = temp_path("env");
        let checker = fake_checker(&format!(
            "#!/bin/sh\n/bin/cat >/dev/null\n/usr/bin/env > {}\nexit 0\n",
            shell_quote(&env_path)
        ));
        let config = ModuleConfig {
            checker,
            fail_policy: FailPolicy::FailClosed,
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::Clean
        );
        let env = std::fs::read_to_string(&env_path).expect("read checker env");
        assert!(env.contains("PWNED_CHECK_FAIL_CLOSED=true"));
        assert!(!env.contains("PWNED_CHECK_SHOULD_NOT_LEAK"));
        assert!(!env.contains("secret"));
        let _ = std::fs::remove_file(env_path);
        std::env::remove_var("PWNED_CHECK_SHOULD_NOT_LEAK");
    }

    #[test]
    fn checker_runner_bounds_stderr_capture() {
        let _guard = checker_test_lock();
        let checker = fake_checker(
            "#!/bin/sh\n/bin/cat >/dev/null\n/usr/bin/yes x | /usr/bin/head -c 2048 >&2\nexit 2\n",
        );
        let config = ModuleConfig {
            checker,
            ..ModuleConfig::default()
        };
        let run = run_checker(&config, b"candidate");

        assert_eq!(run.outcome, CheckerOutcome::ConfigError);
        assert!(run.stderr.len() <= CHECKER_STDERR_LIMIT);
    }

    #[test]
    fn rejected_outcomes_map_to_authtok_error() {
        assert_eq!(
            pam_return_for_decision(ModuleDecision::Reject {
                reason: RejectReason::Pwned
            }),
            PAM_AUTHTOK_ERR
        );
    }

    #[test]
    fn dry_run_allows_runtime_rejections() {
        assert_eq!(
            map_checker_outcome(CheckerOutcome::Pwned, true),
            ModuleDecision::Allow
        );
        assert_eq!(
            pam_return_for_decision(map_checker_outcome(CheckerOutcome::Pwned, true)),
            PAM_SUCCESS
        );
    }

    #[test]
    fn formats_native_pam_result_events() {
        assert_eq!(
            format_result_event(CheckerOutcome::Clean, ModuleDecision::Allow, false),
            "event=pam_module_result result=allow"
        );
        assert_eq!(
            format_result_event(
                CheckerOutcome::Pwned,
                ModuleDecision::Reject {
                    reason: RejectReason::Pwned
                },
                false,
            ),
            "event=pam_module_result result=reject reason=pwned"
        );
        assert_eq!(
            format_result_event(CheckerOutcome::Pwned, ModuleDecision::Allow, true),
            "event=pam_module_result result=allow mode=dry_run would=reject reason=pwned"
        );
    }

    #[test]
    fn formats_native_pam_failure_events() {
        assert_eq!(format_failure_event(CheckerOutcome::Clean, 3), None);
        assert_eq!(format_failure_event(CheckerOutcome::Pwned, 3), None);
        assert_eq!(
            format_failure_event(CheckerOutcome::ConfigError, 3),
            Some("event=pam_module_failure reason=checker_config code=2".to_string())
        );
        assert_eq!(
            format_failure_event(CheckerOutcome::ProviderFailure, 3),
            Some("event=pam_module_failure reason=checker_provider code=3".to_string())
        );
        assert_eq!(
            format_failure_event(CheckerOutcome::Timeout, 7),
            Some("event=pam_module_failure reason=timeout timeout=7s".to_string())
        );
        assert_eq!(
            format_failure_event(CheckerOutcome::ExecFailure, 3),
            Some("event=pam_module_failure reason=exec".to_string())
        );
        assert_eq!(
            format_failure_event(CheckerOutcome::UnexpectedExit(9), 3),
            Some("event=pam_module_failure reason=checker_exit code=9".to_string())
        );
    }

    #[test]
    fn formats_debug_config_without_paths_or_secrets() {
        let config = ModuleConfig {
            checker: "/secret/path/pwned-check".to_string(),
            timeout_seconds: 9,
            fail_policy: FailPolicy::FailClosed,
            dry_run: true,
            debug: true,
        };
        let event = format_config_event(&config);

        assert_eq!(
            event,
            "event=pam_module_config timeout=9s fail_policy=fail_closed dry_run=true"
        );
        assert!(!event.contains("secret"));
        assert!(!event.contains("pwned-check"));
    }

    #[test]
    fn safe_conversation_strings_are_exact() {
        assert_eq!(
            PWNED_REJECTION_MESSAGE,
            "This password appears in a known breach corpus. Choose a different password."
        );
        assert_eq!(
            CHECK_FAILURE_MESSAGE,
            "Password breach check failed. Try again later or contact your administrator."
        );
    }

    #[test]
    fn exported_service_stubs_are_inert_except_prelim_chauthtok() {
        assert_eq!(
            pam_sm_authenticate(core::ptr::null_mut(), 0, 0, core::ptr::null()),
            PAM_IGNORE
        );
        assert_eq!(
            pam_sm_setcred(core::ptr::null_mut(), 0, 0, core::ptr::null()),
            PAM_IGNORE
        );
        assert_eq!(
            pam_sm_acct_mgmt(core::ptr::null_mut(), 0, 0, core::ptr::null()),
            PAM_IGNORE
        );
        assert_eq!(
            pam_sm_open_session(core::ptr::null_mut(), 0, 0, core::ptr::null()),
            PAM_IGNORE
        );
        assert_eq!(
            pam_sm_close_session(core::ptr::null_mut(), 0, 0, core::ptr::null()),
            PAM_IGNORE
        );
        assert_eq!(
            pam_sm_chauthtok(
                core::ptr::null_mut(),
                PAM_PRELIM_CHECK,
                0,
                core::ptr::null()
            ),
            PAM_SUCCESS
        );
        assert_eq!(
            pam_sm_chauthtok(
                core::ptr::null_mut(),
                PAM_UPDATE_AUTHTOK,
                0,
                core::ptr::null()
            ),
            PAM_AUTHTOK_ERR
        );
    }

    fn fake_checker(script: &str) -> String {
        let path = temp_path("checker");
        let mut file = std::fs::File::create(&path).expect("create fake checker");
        file.write_all(script.as_bytes())
            .expect("write fake checker");
        drop(file);

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut permissions = std::fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o700);
            std::fs::set_permissions(&path, permissions).unwrap();
        }

        path.to_string_lossy().into_owned()
    }

    fn temp_path(label: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "pam-pwned-check-test-{label}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
    }

    fn shell_quote(path: &std::path::Path) -> String {
        format!("'{}'", path.to_string_lossy().replace('\'', "'\\''"))
    }

    fn checker_test_lock() -> MutexGuard<'static, ()> {
        CHECKER_TEST_LOCK.lock().expect("checker test lock")
    }
}
