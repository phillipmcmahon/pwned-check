#![deny(unsafe_op_in_unsafe_fn)]

use core::ffi::{c_char, c_int, c_void};
use std::ffi::CStr;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const DEFAULT_CHECKER: &str = "/usr/local/bin/pwned-check";
const DEFAULT_TIMEOUT_SECONDS: u64 = 3;
const CHECKER_STDERR_LIMIT: usize = 512;

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
unsafe extern "C" {
    fn pam_get_item(pamh: *const PamHandle, item_type: c_int, item: *mut *const c_void) -> c_int;
    fn free(ptr: *mut c_void);
}

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
                    let _ = child.kill();
                    let _ = child.wait();
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

fn emit_result(outcome: CheckerOutcome, decision: ModuleDecision, dry_run: bool) {
    if dry_run {
        match outcome {
            CheckerOutcome::Clean => eprintln!("event=pam_module_result result=allow mode=dry_run"),
            _ => eprintln!(
                "event=pam_module_result result=allow mode=dry_run would=reject reason={}",
                reason_name(reject_reason_for_outcome(outcome))
            ),
        }
        return;
    }

    match decision {
        ModuleDecision::Allow => eprintln!("event=pam_module_result result=allow"),
        ModuleDecision::Reject { reason } => {
            eprintln!(
                "event=pam_module_result result=reject reason={}",
                reason_name(reason)
            );
        }
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
                eprintln!("event=pam_module_failure reason=checker_config");
                return PAM_AUTHTOK_ERR;
            }
        };

        let mut candidate = match unsafe { get_authtok(pamh) } {
            Ok(candidate) if !candidate.is_empty() => candidate,
            _ => {
                unsafe { send_pam_error(pamh, CHECK_FAILURE_MESSAGE) };
                eprintln!("event=pam_module_failure reason=missing_authtok");
                return PAM_AUTHTOK_ERR;
            }
        };

        let checker = run_checker(&config, &candidate);
        candidate.fill(0);
        let decision = map_checker_outcome(checker.outcome, config.dry_run);
        emit_result(checker.outcome, decision, config.dry_run);

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
        let path = std::env::temp_dir().join(format!(
            "pam-pwned-check-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
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
}
