# Operational Troubleshooting

This guide maps common rollout symptoms to safe diagnostics and likely fixes.

## Checker Exit Codes

See [Checker contract](checker-contract.md) for the canonical checker exit-code contract.

| Exit code | Operator action |
|---|---|
| `0` | Check stderr events to distinguish clean from fail-open provider failure. |
| `1` | Expected rejection. Confirm no plaintext was logged. |
| `2` | Check environment variables and command flags. |
| `3` | Check HIBP reachability, DNS, proxy/firewall rules, and timeout values. |

## PAM Helper Symptoms

| Log event | Meaning | Operator action |
|---|---|---|
| `event=pam_helper_result result=allow` | Password-change flow can continue. | No action unless this appears during expected rejection tests. |
| `event=pam_helper_result result=reject reason=pwned` | Candidate was found in the breach corpus. | Expected for known pwned test passwords. |
| `event=pam_helper_failure reason=timeout` | Checker exceeded helper timeout. | Increase helper timeout only after checking provider timeout and network behavior. |
| `event=pam_helper_failure reason=checker_config` | Checker configuration is invalid. | Validate provider, endpoint, timeout, and fail-closed environment. |
| `event=pam_helper_failure reason=checker_provider` | Checker hit provider failure in fail-closed mode. | Confirm live HIBP reachability or switch to fail-open if availability is the priority. |
| `event=pam_helper_failure reason=checker_exit` | Checker returned an unexpected code. | Capture version and command configuration, then investigate as a defect. |

For checker configuration, provider, and unexpected-exit failures, the helper may include a bounded `checker_stderr` excerpt. This field is intended for operational triage and should contain only the checker's safe event output.

## Native PAM Module Symptoms

| Symptom | Likely cause | Safe action |
|---|---|---|
| Password changes still succeed during rollout but logs show `mode=dry_run` | Expected dry-run behavior. | Review would-be rejections, then plan enforcement only after rollback is tested. |
| `pam_chauthtok` reports module load failure | Module installed in the wrong security directory or package removal left a stale PAM line. | Disable the package profile/helper, confirm the distro module path, then reinstall or roll back. |
| Fedora/RHEL `authselect check` fails after enablement | Custom profile drift or interrupted enablement. | Run the packaged rollback helper and restore the recorded authselect backup. |
| Debian/Ubuntu `common-password` still references the module after removal | The native PAM profile was not disabled before package removal. | Reinstall the package temporarily, run `pwned-check-pam-disable`, then remove the package. If the wrapper is unavailable, restore `/usr/share/pam-configs/pwned-check` and run `pam-auth-update --disable pwned-check --package`. |
| Arch/Alpine service file still references the module after rollback | Manual helper state file points at the wrong backup or the service path was overridden. | Run rollback with the explicit backup path, or restore the timestamped backup under `/var/lib/pwned-check/pam-backups/`. |
| SELinux AVCs mention `pwned-check` or `pam_pwned_check` | Local policy blocks the checker path or network behavior from the password-change domain. | Keep enforcement disabled, collect the AVCs, and apply the operator-managed policy decision before retrying. |
| AppArmor denials mention `pwned-check`, `pam_pwned_check`, or the native PAM smoke service | Local AppArmor policy blocks the checker or PAM module path. | Keep enforcement disabled, run `make native-pam-ubuntu-hardening-assessment`, and inspect the combined report under `.test-output/native-pam-ubuntu-hardening-assessment/latest/`. |

Package-specific rollback commands are in [Operations](operations.md#native-pam-emergency-recovery).

## Common Checks

Confirm binaries:

```bash
/usr/local/bin/pwned-check --version
/usr/local/bin/pwned-check-pam-helper --version
```

Check live HIBP reachability from the host:

```bash
curl -fsS https://api.pwnedpasswords.com/range/5BAA6 >/dev/null
```

Check fail-open behavior:

```bash
printf 'password\n' | \
  PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/ \
  PWNED_CHECK_FAIL_CLOSED=false \
  /usr/local/bin/pwned-check --stdin
echo $?
```

Expected exit code: `0` with `event=provider_failure fail_closed=false`.

Check fail-closed behavior:

```bash
printf 'password\n' | \
  PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/ \
  PWNED_CHECK_FAIL_CLOSED=true \
  /usr/local/bin/pwned-check --stdin
echo $?
```

Expected exit code: `3` with `event=provider_failure fail_closed=true`.

## Safe Escalation Data

When opening an issue, include:

- binary versions
- OS and distro version
- relevant environment variable names and non-secret values
- exit code
- safe `event=...` log lines
- whether fail-open or fail-closed was selected

Do not include plaintext passwords, full hashes, hash suffixes, account passwords, or production PAM files containing unrelated local policy.
