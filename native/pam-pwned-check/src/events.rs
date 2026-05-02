#[cfg(target_os = "linux")]
use core::ffi::{c_char, c_int};

use crate::checker::CheckerOutcome;
use crate::config::{FailPolicy, ModuleConfig};
use crate::pam_ffi::{CHECK_FAILURE_MESSAGE, PWNED_REJECTION_MESSAGE};

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

#[cfg(target_os = "linux")]
// Rust 2021 extern syntax is intentional until the distro MSRV/edition pin changes.
extern "C" {
    fn openlog(ident: *const c_char, option: c_int, facility: c_int);
    fn syslog(priority: c_int, format: *const c_char, ...);
}

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

pub(crate) fn rejection_message(reason: RejectReason) -> &'static str {
    match reason {
        RejectReason::Pwned => PWNED_REJECTION_MESSAGE,
        RejectReason::CheckerConfig
        | RejectReason::CheckerProvider
        | RejectReason::Timeout
        | RejectReason::Exec
        | RejectReason::CheckerExit => CHECK_FAILURE_MESSAGE,
    }
}

pub(crate) fn emit_config(config: &ModuleConfig) {
    if config.debug {
        emit_log_event(&format_config_event(config));
    }
}

pub(crate) fn emit_result(
    outcome: CheckerOutcome,
    decision: ModuleDecision,
    config: &ModuleConfig,
) {
    if let Some(event) = format_failure_event(outcome, config.timeout_seconds) {
        emit_log_event(&event);
    }

    emit_log_event(&format_result_event(outcome, decision, config.dry_run));
}

pub(crate) fn format_result_event(
    outcome: CheckerOutcome,
    decision: ModuleDecision,
    dry_run: bool,
) -> String {
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

pub(crate) fn format_failure_event(
    outcome: CheckerOutcome,
    timeout_seconds: u64,
) -> Option<String> {
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

pub(crate) fn format_config_event(config: &ModuleConfig) -> String {
    let min_count = config
        .min_count
        .map(|value| format!(" min_count={value}"))
        .unwrap_or_default();
    format!(
        "event=pam_module_config timeout={}s{} fail_policy={} dry_run={}",
        config.timeout_seconds,
        min_count,
        fail_policy_name(config.fail_policy),
        config.dry_run
    )
}

pub(crate) fn emit_log_event(event: &str) {
    #[cfg(target_os = "linux")]
    {
        if let Ok(c_event) = std::ffi::CString::new(event) {
            unsafe {
                // SAFETY: SYSLOG_IDENT and SYSLOG_FORMAT are NUL-terminated static
                // byte strings, so libc never observes a dangling ident or format pointer.
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
