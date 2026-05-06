# Deployment Security Checklist

Use this checklist before enabling `pwned-check` in a Linux password-change path.

## Pre-Deployment

- Confirm the deployment will use the live HIBP Pwned Passwords range API.
- Choose and document fail-open or fail-closed behavior.
- Install the native PAM package from the signed distro repository where possible.
- Verify the repository public key, signed metadata, and production readiness evidence from the [Production release gate](production-release-gate.md).
- Confirm the repository key fingerprint and rotation/revocation notice path in [Package repositories](package-repositories.md#key-rotation-and-revocation).
- Confirm `pwned-check --version`.
- Confirm `pam_pwned_check.so` is installed in the distro PAM security module directory and `pwned-check-pam-disable` is available.
- Set a provider timeout with `PWNED_CHECK_TIMEOUT` and a native module timeout with `timeout=<seconds>` when overriding package defaults.
- Review [Provider policy](provider-policy.md), [Security model](security-model.md), and [Logging policy](logging-policy.md).

## Secret Handling

- Pass candidate passwords over stdin only.
- Do not put passwords in command-line arguments.
- Do not persist password candidates in shell history, files, telemetry, or examples.
- Confirm logs do not include plaintext passwords, full hashes, or hash suffixes.

## PAM Rollout

- Test first in a disposable VM or non-production host.
- Keep an existing root shell open while changing PAM files.
- Use the package enablement command so rollback state is recorded.
- Confirm the pwned-check PAM line appears before the local password update module.
- Test a known pwned password and a strong random password.
- Test provider outage behavior for the selected fail-open/fail-closed posture.

## Rollback

- Keep the original PAM file backup until rollout is complete.
- Know the command to restore the previous PAM file or disable the native PAM package profile.
- Know how to switch from fail-closed to fail-open during a provider outage.
- Verify `passwd` reaches the normal password-change flow after rollback.
- For repository-backed deployments, rehearse package removal and repository disablement before production enforcement.

## Ongoing Checks

- Count safe validation and failure events during rollout.
- Investigate repeated provider failures, module timeouts, or checker config failures.
- Re-verify package checksums and metadata during upgrades.
- Track repository key rotation, revocation notices, and operator trust-store updates.
- Re-run VM-backed package smokes for every available architecture after packaging or PAM behavior changes.
