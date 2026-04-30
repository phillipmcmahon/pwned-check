#![deny(unsafe_op_in_unsafe_fn)]

use core::ffi::{c_char, c_int, c_void};

const DEFAULT_CHECKER: &str = "/usr/local/bin/pwned-check";
const DEFAULT_TIMEOUT_SECONDS: u64 = 3;

pub const PWNED_REJECTION_MESSAGE: &str =
    "This password appears in a known breach corpus. Choose a different password.";
pub const CHECK_FAILURE_MESSAGE: &str =
    "Password breach check failed. Try again later or contact your administrator.";

const PAM_SUCCESS: c_int = 0;
const PAM_IGNORE: c_int = 25;
const PAM_AUTHTOK_ERR: c_int = 20;

const PAM_PRELIM_CHECK: c_int = 0x4000;
const PAM_UPDATE_AUTHTOK: c_int = 0x2000;

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
    _pamh: *mut PamHandle,
    flags: c_int,
    _argc: c_int,
    _argv: *const *const c_char,
) -> c_int {
    if flags & PAM_PRELIM_CHECK != 0 {
        return PAM_SUCCESS;
    }

    if flags & PAM_UPDATE_AUTHTOK != 0 {
        return PAM_IGNORE;
    }

    PAM_IGNORE
}

#[allow(dead_code)]
type PamItem = *const c_void;

#[cfg(test)]
mod tests {
    use super::*;

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
            PAM_IGNORE
        );
    }
}
