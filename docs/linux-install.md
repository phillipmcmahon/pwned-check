# Linux Install And Operations Guide

This is the complete user guide for Linux. It describes the application as it
is today: install the native PAM package from a signed repository, enable
dry-run, validate logs and rollback, then switch to enforcement.

Operators should install from the package repository for their distro family.

Package installation only places files on disk. PAM is not changed until an
enable command is run.

Repository availability and response objectives are documented in the
[production baseline SLO](roadmap.md#production-baseline-slo).

## Supported Platforms

| Platform | Repository | Architectures |
|---|---|---|
| Debian/Ubuntu | Apt | `amd64`, `arm64` |
| Fedora/RHEL/Rocky | DNF/Yum | `x86_64`, `aarch64` |
| Arch Linux | Pacman | `x86_64` |
| Alpine Linux-PAM | APK | `x86_64`, `aarch64` |

Arch Linux ARM is not targeted. Alpine requires Linux-PAM; BusyBox-only
authentication is outside scope.

## Trust Keys

Verify repository keys before installation and before enabling PAM.

| Repository | Expected trust value |
|---|---|
| Apt, DNF/Yum, Arch | OpenPGP fingerprint: `BDF6 F4DD 343E 9F10 EA9D  B510 FDDA 2848 A95A D641` |
| Alpine | RSA public key SHA256: `8CC2BD76F364D3734C8A265B152FCEFFA6F3B90FC2857DB92D40BED4808F214F` |

Key rotation, revocation, and repository publication details are maintained in
[Package repositories](package-repositories.md).

## Install

### Debian Or Ubuntu

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://phillipmcmahon.github.io/pwned-check/pwned-check-openpgp-production.asc |
  sudo tee /etc/apt/keyrings/pwned-check-native-pam.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/pwned-check-native-pam.asc] https://phillipmcmahon.github.io/pwned-check/apt stable main" |
  sudo tee /etc/apt/sources.list.d/pwned-check-native-pam.list >/dev/null
sudo apt update
sudo apt install pwned-check-native-pam
```

### Fedora, RHEL, Or Rocky

```bash
sudo install -d -m 0755 /etc/pki/rpm-gpg
curl -fsSL https://phillipmcmahon.github.io/pwned-check/rpm/RPM-GPG-KEY-pwned-check-native-pam.asc |
  sudo tee /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam >/dev/null
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
sudo tee /etc/yum.repos.d/pwned-check-native-pam.repo >/dev/null <<'EOF'
[pwned-check-native-pam]
name=pwned-check native PAM repository
baseurl=https://phillipmcmahon.github.io/pwned-check/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
EOF
sudo dnf install pwned-check-native-pam
```

Use `yum` instead of `dnf` only on systems where `dnf` is unavailable.

### Arch Linux

```bash
curl -fsSL https://phillipmcmahon.github.io/pwned-check/pwned-check-openpgp-production.asc \
  -o /tmp/pwned-check-native-pam.asc
sudo pacman-key --add /tmp/pwned-check-native-pam.asc
sudo pacman-key --lsign-key BDF6F4DD343E9F10EA9DB510FDDA2848A95AD641
sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[pwned-check]
SigLevel = Required DatabaseRequired
Server = https://phillipmcmahon.github.io/pwned-check/arch/$arch
EOF
sudo pacman -Sy pwned-check-native-pam
```

### Alpine Linux-PAM

```bash
curl -fsSL https://phillipmcmahon.github.io/pwned-check/alpine/pwned-check-alpine-production.rsa.pub |
  sudo tee /etc/apk/keys/pwned-check-alpine-production.rsa.pub >/dev/null
echo "https://phillipmcmahon.github.io/pwned-check/alpine" |
  sudo tee -a /etc/apk/repositories >/dev/null
sudo apk update
sudo apk add pwned-check-native-pam
```

Do not use `--allow-untrusted` for production installs.

## Before Enabling PAM

Confirm these items before running an enable command:

- the host should use the live HIBP Pwned Passwords range API
- the selected provider-failure posture is understood; enable commands default
  to `--fail-open`
- the repository key or Alpine RSA key matches the value in this guide
- `pwned-check --version` reports the expected package version
- `pam_pwned_check.so` is installed in the distro PAM security module directory
- `pwned-check-pam-disable` is available
- a privileged shell is already open for rollback
- rollout starts on a disposable VM, non-production host, or dedicated test
  account

## Enable Dry-Run

Keep an existing privileged shell open until rollback has been tested.

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-enable-dry-run --fail-open
sudo journalctl -t pwned-check -n 20 --no-pager
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-dry-run --fail-open
sudo journalctl -t pwned-check -n 20 --no-pager
```

Use `--fail-closed` instead of `--fail-open` only if provider outages should
block password changes.

Dry-run allows password changes but logs what enforcement would have done. A
known pwned password should produce a safe log line similar to:

```text
event=pam_module_result result=allow mode=dry_run would=reject reason=pwned
```

## Validate Rollback

Before enforcement, prove that rollback works.

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-disable
sudo passwd <test-user>
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
sudo passwd <test-user>
```

After rollback succeeds, enable dry-run again before switching to enforcement.

## Enable Enforcement

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-enable-dry-run --fail-open
sudo pwned-check-pam-enable-enforce --fail-open
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-dry-run --fail-open
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-enforce --fail-open
```

For fail-closed enforcement, use `--fail-closed` on both the dry-run and
enforcement enable commands.

Test with a dedicated non-production user:

1. Try a known pwned password such as `password`.
2. Confirm the password is rejected with:

   ```text
   This password appears in a known breach corpus. Choose a different password.
   ```

3. Retry with a strong random password and confirm the password change succeeds.

## Disable Or Remove

Disable first:

```bash
sudo pwned-check-pam-disable
```

For Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
```

Then remove the package if required:

```bash
sudo apt remove pwned-check-native-pam      # Debian/Ubuntu
sudo dnf remove pwned-check-native-pam      # Fedora/RHEL/Rocky
sudo pacman -R pwned-check-native-pam       # Arch
sudo apk del pwned-check-native-pam         # Alpine Linux-PAM
```

## Emergency Recovery

If password changes behave unexpectedly, disable the module first and keep the
existing shell open:

```bash
sudo pwned-check-pam-disable
```

For Arch and Alpine Linux-PAM, include the service path:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-disable
```

Confirm the module line is gone:

```bash
! grep pam_pwned_check.so /etc/pam.d/common-password
! grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth
! grep pam_pwned_check.so /etc/pam.d/passwd
```

If sudo or password changes are already affected, boot single-user mode or a
rescue image, mount the root filesystem, and remove the `pam_pwned_check.so`
line from the affected PAM service. On Fedora/RHEL/Rocky, restore the recorded
authselect backup when possible instead of editing generated PAM files directly.

## Troubleshooting

| Symptom | Check |
|---|---|
| Package cannot be installed | Run the package manager update command again and confirm the repository key fingerprint or SHA256. |
| Enable command fails | Re-run with `sudo`, confirm the fail-policy option is either `--fail-open` or `--fail-closed`, and check the command output. |
| Password changes are allowed in dry-run | Expected. Check `journalctl -t pwned-check` for `would=reject`. |
| Known pwned password is allowed in enforcement | Confirm the PAM line does not include `dry_run` and that `pwned-check --version` returns the expected package version. |
| Password changes fail during provider outage | Confirm whether the enable command was run with `--fail-closed`. Package defaults use `--fail-open`. |
| Need the exact checker exit-code behavior | See [Checker contract](checker-contract.md). |

Logs are safe to share for diagnosis when they are emitted by `pwned-check`.
They do not include plaintext passwords, full SHA-1 hashes, or hash suffixes.

## Standalone Checker

```bash
pwned-check --version
printf 'password\n' | pwned-check --stdin
echo $?
```

Exit codes:

| Code | Meaning |
|---|---|
| `0` | Clean, or provider failure when fail-open is enabled |
| `1` | Pwned password at or above the configured threshold |
| `2` | Configuration or usage error |
| `3` | Provider or network error when fail-closed is enabled |

Useful options:

```bash
pwned-check --stdin --min-count 10
PWNED_CHECK_FAIL_CLOSED=1 pwned-check --stdin
```

The canonical checker behavior is maintained in
[Checker contract](checker-contract.md).
