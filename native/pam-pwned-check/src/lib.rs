#![deny(unsafe_op_in_unsafe_fn)]

mod checker;
mod config;
mod events;
mod pam_ffi;

pub use checker::{run_checker, CheckerOutcome, CheckerRun};
pub use config::{parse_module_config, ConfigError, FailPolicy, ModuleConfig};
pub use events::{map_checker_outcome, ModuleDecision, RejectReason};
pub use pam_ffi::{
    pam_return_for_decision, pam_sm_acct_mgmt, pam_sm_authenticate, pam_sm_chauthtok,
    pam_sm_close_session, pam_sm_open_session, pam_sm_setcred, PamHandle, CHECK_FAILURE_MESSAGE,
    PWNED_REJECTION_MESSAGE,
};

#[cfg(test)]
pub(crate) use checker::CHECKER_STDERR_LIMIT;
#[cfg(test)]
pub(crate) use config::parse_module_config_from_argv;
#[cfg(test)]
pub(crate) use events::{format_config_event, format_failure_event, format_result_event};
#[cfg(test)]
pub(crate) use pam_ffi::{
    PAM_AUTHTOK_ERR, PAM_IGNORE, PAM_PRELIM_CHECK, PAM_SUCCESS, PAM_UPDATE_AUTHTOK,
};

#[cfg(test)]
mod tests {
    use super::*;
    use core::ffi::c_int;
    use proptest::prelude::*;
    use std::ffi::CString;
    use std::io::Write;
    use std::sync::{Mutex, MutexGuard};
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    static CHECKER_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn parse_defaults() {
        assert_eq!(
            parse_module_config(&[]).unwrap(),
            ModuleConfig {
                checker: "/usr/local/bin/pwned-check".to_string(),
                timeout_seconds: 3,
                min_count: None,
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
                "min_count=12",
                "fail_closed",
                "dry_run",
                "debug"
            ])
            .unwrap(),
            ModuleConfig {
                checker: "/opt/pwned-check".to_string(),
                timeout_seconds: 9,
                min_count: Some(12),
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
    fn parse_rejects_invalid_min_count() {
        assert_eq!(
            parse_module_config(&["min_count=0"]),
            Err(ConfigError::InvalidMinCount)
        );
        assert_eq!(
            parse_module_config(&["min_count=abc"]),
            Err(ConfigError::InvalidMinCount)
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
    fn parse_from_raw_argv_allows_zero_argc_with_null_argv() {
        assert_eq!(
            unsafe { parse_module_config_from_argv(0, core::ptr::null()) },
            Ok(ModuleConfig::default())
        );
    }

    #[test]
    fn parse_from_raw_argv_rejects_null_argv_when_argc_positive() {
        assert_eq!(
            unsafe { parse_module_config_from_argv(1, core::ptr::null()) },
            Err(ConfigError::NullArgument)
        );
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
            "min_count=0",
            "min_count=999999",
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

    proptest! {
        #![proptest_config(ProptestConfig::with_cases(128))]

        #[test]
        fn parse_module_config_generated_args_do_not_panic(args in prop::collection::vec(any::<String>(), 0..8)) {
            let refs = args.iter().map(String::as_str).collect::<Vec<_>>();
            let _ = parse_module_config(&refs);
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
    fn checker_runner_passes_min_count_argument() {
        let _guard = checker_test_lock();
        let argv_path = temp_path("argv");
        let checker = fake_checker(&format!(
            "#!/bin/sh\nprintf '%s' \"$*\" > {}\n/bin/cat >/dev/null\nexit 0\n",
            shell_quote(&argv_path)
        ));
        let config = ModuleConfig {
            checker,
            min_count: Some(42),
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::Clean
        );
        let argv = std::fs::read_to_string(&argv_path).expect("read checker argv");
        assert_eq!(argv, "--stdin --min-count 42");
        let _ = std::fs::remove_file(argv_path);
    }

    #[test]
    fn checker_runner_passes_min_count_with_fail_closed_policy() {
        let _guard = checker_test_lock();
        let argv_path = temp_path("argv");
        let env_path = temp_path("env");
        let checker = fake_checker(&format!(
            "#!/bin/sh\nprintf '%s' \"$*\" > {}\nprintf '%s' \"${{PWNED_CHECK_FAIL_CLOSED:-}}\" > {}\n/bin/cat >/dev/null\nexit 0\n",
            shell_quote(&argv_path),
            shell_quote(&env_path)
        ));
        let config = ModuleConfig {
            checker,
            min_count: Some(42),
            fail_policy: FailPolicy::FailClosed,
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::Clean
        );
        let argv = std::fs::read_to_string(&argv_path).expect("read checker argv");
        let env = std::fs::read_to_string(&env_path).expect("read checker env");
        assert_eq!(argv, "--stdin --min-count 42");
        assert_eq!(env, "true");
        let _ = std::fs::remove_file(argv_path);
        let _ = std::fs::remove_file(env_path);
    }

    #[test]
    fn checker_runner_passes_null_byte_candidate_over_stdin() {
        let _guard = checker_test_lock();
        let stdin_path = temp_path("stdin");
        let checker = fake_checker(&format!(
            "#!/bin/sh\n/bin/cat > {}\nexit 0\n",
            shell_quote(&stdin_path)
        ));
        let config = ModuleConfig {
            checker,
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"prefix\0suffix").outcome,
            CheckerOutcome::Clean
        );
        let stdin = std::fs::read(&stdin_path).expect("read checker stdin");
        assert_eq!(stdin, b"prefix\0suffix");
        let _ = std::fs::remove_file(stdin_path);
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
            "#!/bin/sh\n/bin/cat >/dev/null\n/usr/bin/yes x | /usr/bin/head -c 131072 >&2\nexit 2\n",
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
    fn checker_runner_rejects_missing_checker_before_spawn() {
        let _guard = checker_test_lock();
        let marker_path = temp_path("missing-checker-marker");
        let config = ModuleConfig {
            checker: format!("{}-absent", marker_path.display()),
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::ExecFailure
        );
        assert!(
            !std::path::Path::new(&marker_path).exists(),
            "missing checker test should not create marker path"
        );
    }

    #[test]
    fn checker_runner_rejects_non_executable_checker_before_spawn() {
        let _guard = checker_test_lock();
        let checker = temp_path("non-executable-checker");
        std::fs::write(&checker, "#!/bin/sh\nexit 0\n").expect("write non-executable checker");
        let config = ModuleConfig {
            checker: checker.to_string_lossy().into_owned(),
            ..ModuleConfig::default()
        };

        assert_eq!(
            run_checker(&config, b"candidate").outcome,
            CheckerOutcome::ExecFailure
        );
        let _ = std::fs::remove_file(checker);
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
            min_count: Some(7),
            fail_policy: FailPolicy::FailClosed,
            dry_run: true,
            debug: true,
        };
        let event = format_config_event(&config);

        assert_eq!(
            event,
            "event=pam_module_config timeout=9s min_count=7 fail_policy=fail_closed dry_run=true"
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
        assert_eq!(
            pam_sm_chauthtok(
                core::ptr::null_mut(),
                PAM_UPDATE_AUTHTOK,
                1,
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
