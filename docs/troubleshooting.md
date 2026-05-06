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

## Native PAM Module Symptoms

| Symptom | Likely cause | Safe action |
|---|---|---|
| Password changes still succeed during rollout but logs show `mode=dry_run` | Expected dry-run behavior. | Review would-be rejections, then plan enforcement only after rollback is tested. |
| `pam_chauthtok` reports module load failure | Module installed in the wrong security directory or package removal left a stale PAM line. | Disable the package profile, confirm the distro module path, then reinstall or roll back. |
| Fedora/RHEL `authselect check` fails after enablement | Custom profile drift or interrupted enablement. | Run `pwned-check-pam-disable` and restore the recorded authselect backup. |
| Debian/Ubuntu `common-password` still references the module after removal | The native PAM profile was not disabled before package removal. | Reinstall the package temporarily, run `pwned-check-pam-disable`, then remove the package. If the wrapper is unavailable, restore `/usr/share/pam-configs/pwned-check` and run `pam-auth-update --disable pwned-check --package`. |
| Arch/Alpine service file still references the module after rollback | Package wrapper state points at the wrong backup or the service path was overridden. | Run rollback with the explicit backup path, or restore the timestamped backup under `/var/lib/pwned-check/pam-backups/`. |
| SELinux AVCs mention `pwned-check` or `pam_pwned_check` | Local policy blocks the checker path or network behavior from the password-change domain. | Keep enforcement disabled, collect the AVCs, and apply the operator-managed policy decision before retrying. |
| AppArmor denials mention `pwned-check`, `pam_pwned_check`, or the native PAM smoke service | Local AppArmor policy blocks the checker or PAM module path. | Keep enforcement disabled, run `make native-pam-ubuntu-hardening-assessment`, and inspect the combined report under `.test-output/native-pam-ubuntu-hardening-assessment/latest/`. |

Package-specific rollback commands are in [Operations](operations.md#emergency-recovery).

## Repository Trust Symptoms

| Symptom | Likely cause | Safe action |
|---|---|---|
| Package manager reports an expired repository signing key | Planned rotation was missed or the host has stale public-key material. | Follow the expired-key recovery path in [Package repositories](package-repositories.md#key-rotation-and-revocation), verify the replacement fingerprint through release notes, then refresh package metadata. |
| Package manager reports an unknown or untrusted repository key | Public key was not installed, was installed under the wrong trust path, or was not locally trusted for pacman. | Reinstall the documented public key for the distro family and verify the fingerprint before retrying. |
| Revocation notice names the installed repository key | Repository key compromise or emergency rotation. | Stop upgrades from that repository, remove the affected key, install the replacement key, refresh metadata, and upgrade only to the corrected release named in the notice. |
| Repository metadata verifies but package payload has changed at the same version | Published payload was replaced in place. | Treat this as a release incident. Do not enable the module from that repository until maintainers publish a corrected patch release and incident notes. |

## Common Checks

Confirm binaries:

```bash
command -v pwned-check
pwned-check --version
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
  pwned-check --stdin
echo $?
```

Expected exit code: `0` with `event=provider_failure fail_closed=false`.

Check fail-closed behavior:

```bash
printf 'password\n' | \
  PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/ \
  PWNED_CHECK_FAIL_CLOSED=true \
  pwned-check --stdin
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
