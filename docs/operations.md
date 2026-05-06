# Operations

This runbook covers Linux installation, native PAM enablement, rollback, and emergency recovery. The supported operator path is the native PAM package installed from a signed distro repository.

## Native PAM Package Model

Native PAM packages are distributed through signed package repositories.
Package installation places files on disk only; it does not enable PAM.
Operators explicitly enable `dry_run` first, validate logs and rollback, and
only then switch to enforcement.

All native package families install the same commands:

| Command | Purpose |
|---|---|
| `pwned-check-pam-enable-dry-run` | Enable the native module in dry-run mode and record rollback state |
| `pwned-check-pam-enable-enforce` | Switch an enabled dry-run config to enforcement |
| `pwned-check-pam-disable` | Restore the recorded PAM or authselect rollback state |

Debian/Ubuntu, Fedora/RHEL/Rocky, and Alpine install these commands under
`/usr/sbin`; Arch installs them under `/usr/bin`. Prefer calling the command
name instead of hard-coding the path.

For repository-backed packages, verify the repository public key fingerprint
before installation and before enabling the PAM module. Key rotation,
expired-key recovery, compromised-key recovery, and exact repository setup
commands are maintained in
[Package repositories](package-repositories.md#key-rotation-and-revocation).

## Install From Package Repositories

Use the signed package repositories for normal operator installs:

| Distro family | Repository instructions |
|---|---|
| Debian/Ubuntu | [Apt repository](package-repositories.md#apt-repository) |
| Fedora/RHEL/Rocky | [RPM repository](package-repositories.md#rpm-repository) |
| Arch Linux | [Arch repository](package-repositories.md#arch-repository) |
| Alpine Linux-PAM | [Alpine repository](package-repositories.md#alpine-repository) |

After installation, continue with dry-run, enforcement, disable, and package
removal. The repository path should not require GitHub credentials, build
tools, private signing keys, or a local checkout on the target host.

## Enable Dry-Run

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-enable-dry-run
sudo journalctl -t pwned-check -n 20 --no-pager
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-dry-run
sudo journalctl -t pwned-check -n 20 --no-pager
```

The module obtains the candidate through existing `PAM_AUTHTOK` state when
present, or through Linux PAM's `pam_get_authtok` API when it is the first
password module that needs the token. Debian/Ubuntu deployments do not need
`pam_pwquality` solely to collect the password.

## Switch To Enforcement

Switch only after dry-run logs and rollback have been validated.

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-enable-enforce
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-enforce
```

## Disable

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-disable
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
```

For Fedora/RHEL/Rocky, prefer the disable command because it restores the
recorded authselect backup. Avoid hand-editing generated `system-auth` or
`password-auth` unless you are in emergency recovery.

## Remove Package

```bash
sudo apt remove pwned-check-native-pam      # Debian/Ubuntu
sudo dnf remove pwned-check-native-pam      # Fedora/RHEL/Rocky
sudo pacman -R pwned-check-native-pam       # Arch
sudo apk del pwned-check-native-pam         # Alpine Linux-PAM
```

## Validate Before Enforcement

Use a dedicated non-production user. Keep an existing privileged shell open until rollback has been tested.

1. Enable dry-run.
2. Run a password change for the test user with a known pwned password such as `password`.
3. Confirm the log records `result=allow mode=dry_run would=reject reason=pwned`.
4. Run `pwned-check-pam-disable` and confirm password changes still work.
5. Re-enable dry-run, switch to enforcement, and retry the pwned password.
6. Confirm the password is rejected with the approved message:

```text
This password appears in a known breach corpus. Choose a different password.
```

7. Retry with a strong random password and confirm the normal password-change flow succeeds.

## Emergency Recovery

If password changes behave unexpectedly, disable the module first:

Debian/Ubuntu:

```bash
sudo pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/common-password
sudo passwd <test-user>
```

Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth
sudo passwd <test-user>
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/passwd
sudo passwd <test-user>
```

If normal sudo access is already affected, boot single-user mode or a rescue image, mount the root filesystem, and remove the `pam_pwned_check.so` line from the affected PAM service. For Fedora/RHEL/Rocky, restore the recorded authselect backup if possible rather than editing generated PAM files directly.

## Checker Configuration

Environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` for production use; `local` is reserved for tests
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the test-only local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

For production PAM integration, prefer explicit configuration in the integration layer rather than depending on an ambient shell environment.
