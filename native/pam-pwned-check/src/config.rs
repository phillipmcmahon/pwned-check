use core::ffi::{c_char, c_int};
use std::ffi::CStr;

const DEFAULT_CHECKER: &str = "/usr/local/bin/pwned-check";
const DEFAULT_TIMEOUT_SECONDS: u64 = 3;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleConfig {
    pub checker: String,
    pub timeout_seconds: u64,
    pub min_count: Option<u64>,
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
    InvalidMinCount,
    ConflictingFailPolicy,
    InvalidUtf8,
    NullArgument,
    UnknownArgument(String),
}

impl Default for ModuleConfig {
    fn default() -> Self {
        Self {
            checker: DEFAULT_CHECKER.to_string(),
            timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
            min_count: None,
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

        if let Some(value) = arg.strip_prefix("min_count=") {
            let count = value
                .parse::<u64>()
                .ok()
                .filter(|count| *count > 0)
                .ok_or(ConfigError::InvalidMinCount)?;
            config.min_count = Some(count);
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

pub(crate) unsafe fn parse_module_config_from_argv(
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
