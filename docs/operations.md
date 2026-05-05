# Operations

This runbook covers Linux installation, native PAM enablement, rollback, and emergency recovery. Native PAM packages are the preferred Linux deployment path. The helper-based `pam_exec.so expose_authtok` path remains supported for compatibility deployments and is summarized here.

## Native PAM Package Model

Native PAM packages are distributed through signed package repositories for
production-style installs. GitHub Release package assets remain available as an
immutable bootstrap and recovery channel. Package installation places files on
disk only; it does not enable PAM. Operators explicitly enable `dry_run` first,
validate logs and rollback, and only then switch to enforcement.

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

After installation, continue with the dry-run, enforcement, disable, and removal
steps below for the target distro family. The repository path should not require
GitHub credentials, build tools, private signing keys, or a local checkout on
the target host.

## Bootstrap From GitHub Releases

Set the version and release URL:

```bash
VERSION=0.1.6
BASE_URL="https://github.com/phillipmcmahon/pwned-check/releases/download/v${VERSION}"
```

Use GitHub Release package assets when repository access is unavailable, when
recovering a host, or when validating immutable release artifacts directly.
Verify the downloaded `.sha256` file before installation.

### Debian/Ubuntu

Use the architecture reported by `dpkg --print-architecture`, normally `amd64` or `arm64`:

```bash
ARCH="$(dpkg --print-architecture)"
DEB="pwned-check-native-pam_${VERSION}_${ARCH}.deb"

curl -LO "${BASE_URL}/${DEB}"
curl -LO "${BASE_URL}/${DEB}.sha256"
sha256sum -c "${DEB}.sha256"
sudo apt install "./${DEB}"
```

Enable dry-run and confirm the PAM profile was added:

```bash
sudo pwned-check-pam-enable-dry-run
grep pam_pwned_check.so /etc/pam.d/common-password
sudo journalctl -t pwned-check -n 20 --no-pager
```

Switch to enforcement only after dry-run logs and rollback have been validated:

```bash
sudo pwned-check-pam-enable-enforce
```

Disable and remove:

```bash
sudo pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/common-password
sudo apt remove pwned-check-native-pam
```

The module obtains the candidate through existing `PAM_AUTHTOK` state when present, or through Linux PAM's `pam_get_authtok` helper when it is the first password module that needs the token. Debian/Ubuntu deployments do not need `pam_pwquality` solely to collect the password.

### Fedora/RHEL/Rocky

Confirm the exact RPM asset name on the release page because the filename includes the distro tag used by the release build. Example for Fedora x86_64:

```bash
RPM_ASSET="pwned-check-native-pam-${VERSION}-1.fc44.x86_64.rpm"

curl -LO "${BASE_URL}/${RPM_ASSET}"
curl -LO "${BASE_URL}/${RPM_ASSET}.sha256"
sha256sum -c "${RPM_ASSET}.sha256"
sudo dnf install "./${RPM_ASSET}"
```

Enable dry-run and confirm the generated authselect profile:

```bash
sudo pwned-check-pam-enable-dry-run
authselect current
grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth
sudo journalctl -t pwned-check -n 20 --no-pager
```

Switch to enforcement only after dry-run logs and rollback have been validated:

```bash
sudo pwned-check-pam-enable-enforce
```

Disable and remove:

```bash
sudo pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth
sudo dnf remove pwned-check-native-pam
```

For Fedora/RHEL/Rocky, prefer the disable command because it restores the recorded authselect backup. Avoid hand-editing generated `system-auth` or `password-auth` unless you are in emergency recovery.

### Arch Linux

Arch currently publishes x86_64 native PAM packages:

```bash
PKG="pwned-check-native-pam-${VERSION}-1-x86_64.pkg.tar.zst"

curl -LO "${BASE_URL}/${PKG}"
curl -LO "${BASE_URL}/${PKG}.sha256"
sha256sum -c "${PKG}.sha256"
sudo pacman -U "./${PKG}"
```

Enable dry-run against the intended PAM service. The default manual path is usually `/etc/pam.d/passwd`:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-dry-run
grep pam_pwned_check.so /etc/pam.d/passwd
```

Switch to enforcement only after dry-run logs and rollback have been validated:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-enforce
```

Disable and remove:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/passwd
sudo pacman -R pwned-check-native-pam
```

### Alpine Linux-PAM

Alpine support is for Linux-PAM deployments, not BusyBox-only authentication paths.

```bash
APK="pwned-check-native-pam-${VERSION}-r0.apk"

curl -LO "${BASE_URL}/${APK}"
curl -LO "${BASE_URL}/${APK}.sha256"
sha256sum -c "${APK}.sha256"
sudo apk add --allow-untrusted "./${APK}"
```

Enable dry-run against the intended PAM service. The default manual path is usually `/etc/pam.d/passwd`:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-dry-run
grep pam_pwned_check.so /etc/pam.d/passwd
```

Switch to enforcement only after dry-run logs and rollback have been validated:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-enforce
```

Disable and remove:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
! grep pam_pwned_check.so /etc/pam.d/passwd
sudo apk del pwned-check-native-pam
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

## Checker And Helper Tarball Install

The release tarball installs the standalone checker and helper-based PAM integration. Use this path when you do not want the native PAM module package.

Verify the tarball:

```bash
sha256sum -c pwned-check_<version>_linux_<arch>.tar.gz.sha256
tar -tzf pwned-check_<version>_linux_<arch>.tar.gz
```

On macOS, verify against the expected checksum value from the `.sha256` file:

```bash
shasum -a 256 pwned-check_<version>_linux_<arch>.tar.gz
```

Install:

```bash
tar -xzf pwned-check_<version>_linux_<arch>.tar.gz
cd pwned-check_<version>_linux_<arch>
sudo ./install.sh
/usr/local/bin/pwned-check --version
/usr/local/bin/pwned-check-pam-helper --version
```

By default, `install.sh` uses:

- `INSTALL_ROOT=/usr/local/lib/pwned-check`
- `BIN_DIR=/usr/local/bin`

Override locations when needed:

```bash
sudo INSTALL_ROOT=/opt/pwned-check BIN_DIR=/usr/local/bin ./install.sh
```

The installed layout uses versioned binaries with stable symlinks:

```text
/usr/local/lib/pwned-check/
  pwned-check_<version>_linux_<arch>
  pwned-check-pam-helper_<version>_linux_<arch>
  current -> pwned-check_<version>_linux_<arch>
  current-pam-helper -> pwned-check-pam-helper_<version>_linux_<arch>

/usr/local/bin/
  pwned-check -> /usr/local/lib/pwned-check/current
  pwned-check-pam-helper -> /usr/local/lib/pwned-check/current-pam-helper
```

Rollback is a symlink change:

```bash
sudo ln -sfn /usr/local/lib/pwned-check/<previous-binary> /usr/local/lib/pwned-check/current
sudo ln -sfn /usr/local/lib/pwned-check/<previous-helper-binary> /usr/local/lib/pwned-check/current-pam-helper
/usr/local/bin/pwned-check --version
/usr/local/bin/pwned-check-pam-helper --version
```

Helper-based PAM configuration uses the installed `pwned-check-pam-helper` as a
thin timeout wrapper around the checker:

```text
password requisite pam_exec.so expose_authtok quiet /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check --timeout 3s
```

Place the line before `pam_unix.so` in the target password stack so rejected
passwords fail before local password storage changes. The helper reads the
candidate from stdin, invokes `pwned-check --stdin`, never logs the plaintext
password, and maps all reject, timeout, configuration, and fail-closed provider
outcomes to a PAM rejection. Back up the PAM file first, keep a privileged shell
open, test with a disposable user, and restore the backup for rollback.

Do not combine the helper-based `pam_exec.so expose_authtok` line and the native
PAM module in the same password stack unless you are deliberately testing both
paths on a disposable host.

## Checker Configuration

Environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` for production use; `local` is reserved for tests
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the test-only local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

For production PAM integration, prefer explicit configuration in the integration layer rather than depending on an ambient shell environment.
