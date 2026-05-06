# Linux Package Install

This is the normal operator path for `pwned-check` on Linux: add the signed
repository, install `pwned-check-native-pam`, enable dry-run, validate, then
switch to enforcement.

This guide describes the Linux production baseline introduced in v0.3.0. Use
signed repository packages for production installs. GitHub Release package
assets are immutable release artifacts for inspection, recovery, and repository
publication, not the normal operator install path.

Package installation only places files on disk. It does not change PAM until
you run an enable command.

Supported repository families:

| Platform | Repository | Architectures |
|---|---|---|
| Debian/Ubuntu | Apt | `amd64`, `arm64` |
| Fedora/RHEL/Rocky | DNF/Yum | `x86_64`, `aarch64` |
| Arch Linux | Pacman | `x86_64` |
| Alpine Linux-PAM | APK | `aarch64` |

Arch Linux ARM is not targeted. Alpine deployments require Linux-PAM;
BusyBox-only authentication is outside scope.

## Trust Keys

Verify repository keys before installation and before enabling PAM.

| Repository | Expected trust value |
|---|---|
| Apt, DNF/Yum, Arch | OpenPGP fingerprint: `BDF6 F4DD 343E 9F10 EA9D  B510 FDDA 2848 A95A D641` |
| Alpine | RSA public key SHA256: `8CC2BD76F364D3734C8A265B152FCEFFA6F3B90FC2857DB92D40BED4808F214F` |

Key rotation and revocation handling is documented in
[Package repositories](package-repositories.md#key-rotation-and-revocation).

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

Do not use `--allow-untrusted` for production repository installs.

## Enable Dry-Run

Keep an existing privileged shell open until rollback has been tested.

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

Switch only after dry-run logs and rollback have been validated.

Debian/Ubuntu and Fedora/RHEL/Rocky:

```bash
sudo pwned-check-pam-enable-dry-run
sudo pwned-check-pam-enable-enforce
```

Arch and Alpine Linux-PAM:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-dry-run
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  pwned-check-pam-enable-enforce
```

Test with a dedicated non-production user:

1. Try a known pwned password such as `password`.
2. Confirm the password is rejected with:

   ```text
   This password appears in a known breach corpus. Choose a different password.
   ```

3. Retry with a strong random password and confirm the normal password-change
   flow succeeds.

## Disable Or Remove

Disable first:

```bash
sudo pwned-check-pam-disable
```

For Arch and Alpine Linux-PAM, include the service path:

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

Confirm the module line is gone:

```bash
! grep pam_pwned_check.so /etc/pam.d/common-password                 # Debian/Ubuntu
! grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth # Fedora/RHEL/Rocky
! grep pam_pwned_check.so /etc/pam.d/passwd                          # Arch/Alpine
```

If sudo or password changes are already affected, boot single-user mode or a
rescue image, mount the root filesystem, and remove the `pam_pwned_check.so`
line from the affected PAM service. On Fedora/RHEL/Rocky, restore the recorded
authselect backup if possible instead of editing generated PAM files directly.

## Troubleshooting

- Confirm the package installed `pwned-check` and `pam_pwned_check.so`.
- Confirm `pwned-check --version`.
- Check safe logs with `sudo journalctl -t pwned-check -n 100 --no-pager`.
- See [Operational troubleshooting](troubleshooting.md) for symptom-specific
  fixes.
- See [Package repositories](package-repositories.md) for repository trust,
  key rotation, and publication details.
