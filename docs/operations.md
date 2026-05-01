# Operations

This document describes the intended Linux install and rollback model. It will evolve once the PAM integration lands.

## Recommended Install Layout

Use a versioned binary with a stable symlink:

```text
/usr/local/lib/pwned-check/
  pwned-check_<version>_linux_<arch>
  current -> pwned-check_<version>_linux_<arch>

/usr/local/bin/
  pwned-check -> /usr/local/lib/pwned-check/current
  pwned-check-pam-helper -> /usr/local/lib/pwned-check/current-pam-helper
```

Why this layout works well:

- PAM or helper configuration can call `/usr/local/bin/pwned-check`.
- The installed binary remains version-identifiable.
- Upgrades change a symlink rather than PAM configuration.
- Rollback can be a symlink flip.

## Verify a Release Package

Release packages include:

- `pwned-check`
- `pwned-check-pam-helper`
- `install.sh`
- `README.md`
- `LICENSE`
- `metadata/build.json`
- `metadata/go-modules.txt`
- Go build metadata for both binaries

Verify a downloaded package checksum:

```bash
sha256sum -c pwned-check_<version>_linux_<arch>.tar.gz.sha256
```

On macOS:

```bash
shasum -a 256 pwned-check_<version>_linux_<arch>.tar.gz
```

Inspect package contents:

```bash
tar -tzf pwned-check_<version>_linux_<arch>.tar.gz
```

## Debian/Ubuntu Native PAM Artifact

The native PAM module has a Debian/Ubuntu filesystem-layout artifact for the current Linux architecture:

```bash
scripts/package-native-pam-debian-artifact.sh --version <version>
tar -tzf dist/release/pwned-check-native-pam_<version>_debian_<arch>.tar.gz
```

Build the native `.deb` package with:

```bash
scripts/package-native-pam-debian-package.sh --version <version>
dpkg-deb --info dist/release/pwned-check-native-pam_<debian-version>_<arch>.deb
```

Both the staging artifact and the native `.deb` include:

- `/usr/bin/pwned-check`
- `/lib/<multiarch>/security/pam_pwned_check.so`
- `/usr/share/pam-configs/pwned-check`
- `/usr/share/doc/pwned-check/`

The `pam-auth-update` profile is disabled by default and ships with `dry_run` enabled. Package installation should not silently enable enforcement.

Installing the native `pwned-check-native-pam` `.deb` follows the same rule: package installation places files on disk only. Operators must run `pam-auth-update --enable pwned-check --package` explicitly to enable dry-run mode.

Enable the native profile only after installing on a disposable host or VM and keeping a recovery shell open:

```bash
sudo ./install.sh
sudo pam-auth-update --enable pwned-check --package
grep pam_pwned_check.so /etc/pam.d/common-password
```

Rollback should be tested before enforcement rollout:

```bash
sudo pam-auth-update --disable pwned-check --package
! grep pam_pwned_check.so /etc/pam.d/common-password
sudo passwd <test-user>
```

The persistent Ubuntu native PAM smoke test installs this artifact, enables the profile through `pam-auth-update`, asserts the generated password stack, disables the profile again, and restores the container's PAM state between runs.

For native Ubuntu host validation without touching the real password stack, use:

```bash
make native-pam-ubuntu-host-package-smoke
make native-pam-ubuntu-deb-package-smoke
```

That smoke installs the Debian/Ubuntu filesystem layout on the host, creates only a disposable PAM service under `/etc/pam.d`, exercises clean and pwned `pam_chauthtok` cases, and removes the installed files again. It does not run `pam-auth-update --enable`.

The `.deb` package smoke builds and installs the native package, exercises the package-managed files through the same disposable PAM service path, enables and disables the `pam-auth-update` profile, verifies `/etc/pam.d/common-password` is restored, removes the package, and verifies managed-file cleanup.

## Arch/Alpine Native PAM Artifact

Arch and Linux-PAM-enabled Alpine use the generic manual-PAM filesystem-layout artifact as the staging input:

```bash
scripts/package-native-pam-generic-artifact.sh --version <version> --family arch
scripts/package-native-pam-generic-artifact.sh --version <version> --family alpine
```

Build the native Arch package with:

```bash
scripts/package-native-pam-arch-package.sh --version <version>
pacman -Qip dist/release/pwned-check-native-pam-<pkgver>-1-*.pkg.tar.*
```

The staging artifact and native Arch package include:

- `/usr/bin/pwned-check`
- `pam_pwned_check.so` in the distro Linux-PAM security module directory, currently `/usr/lib/security` for Arch and Alpine Linux-PAM
- `/usr/share/pwned-check/manual-pam/enable-manual-pam.sh`
- `/usr/share/pwned-check/manual-pam/rollback-manual-pam.sh`
- `/usr/share/doc/pwned-check/`

Package installation should not silently enable enforcement. The manual helper edits `/etc/pam.d/passwd` by default, stores a timestamped backup under `/var/lib/pwned-check/pam-backups/`, records the latest backup path, and inserts the module in `dry_run` mode.

Installing the native `pwned-check-native-pam` Arch package follows the same rule: package installation places files on disk only. Operators must run the manual helper explicitly to enable dry-run mode.

Enable only after reviewing the target PAM service path:

```bash
sudo ./install.sh
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  /usr/share/pwned-check/manual-pam/enable-manual-pam.sh
grep pam_pwned_check.so /etc/pam.d/passwd
```

Rollback should be tested before enforcement rollout:

```bash
sudo PWNED_CHECK_PAM_SERVICE_PATH=/etc/pam.d/passwd \
  /usr/share/pwned-check/manual-pam/rollback-manual-pam.sh
! grep pam_pwned_check.so /etc/pam.d/passwd
sudo passwd <test-user>
```

## Fedora/RHEL/Rocky Native PAM Artifact

The native PAM module has an RPM-family filesystem-layout artifact for the current Linux architecture:

```bash
scripts/package-native-pam-rpm-artifact.sh --version <version>
tar -tzf dist/release/pwned-check-native-pam_<version>_rpm_<arch>.tar.gz
```

Build the native RPM package with:

```bash
scripts/package-native-pam-rpm-package.sh --version <version>
rpm -qpi dist/release/pwned-check-native-pam-<rpm-version>-1*.rpm
```

Both the staging artifact and the native RPM include:

- `/usr/bin/pwned-check`
- `/lib64/security/pam_pwned_check.so`
- `/usr/share/pwned-check/authselect/enable-authselect.sh`
- `/usr/share/pwned-check/authselect/rollback-authselect.sh`
- `/usr/share/doc/pwned-check/`

Package installation should not silently enable enforcement. The authselect helper creates a `custom/pwned-check` profile from the currently selected profile, inserts the native module at the start of the password stack in `dry_run` mode, selects that custom profile with an authselect backup, and records the backup name under `/var/lib/pwned-check/`.

Installing the native `pwned-check-native-pam` RPM follows the same rule: package installation places files on disk only. Operators must run the authselect helper explicitly to enable dry-run mode.

Enable only after installing on a disposable host or VM and keeping a recovery shell open:

```bash
sudo ./install.sh
sudo /usr/share/pwned-check/authselect/enable-authselect.sh
authselect current
grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth
```

Rollback should be tested before enforcement rollout:

```bash
sudo /usr/share/pwned-check/authselect/rollback-authselect.sh
! grep pam_pwned_check.so /etc/pam.d/system-auth /etc/pam.d/password-auth
sudo passwd <test-user>
```

For host-level smoke validation on Fedora/RHEL-family test machines, use:

```bash
make native-pam-fedora-host-package-smoke
make native-pam-fedora-rpm-package-smoke
```

That smoke installs the RPM-family filesystem layout, exercises the installed module through a disposable PAM service, enables a temporary authselect profile, verifies the active authselect-managed stacks, restores the authselect backup, and removes the installed test files.

The RPM package smoke builds and installs the native RPM, exercises the package-managed files through the same PAM/authselect path, removes the package, and verifies managed-file cleanup.

## Install from a Release Package

```bash
tar -xzf pwned-check_<version>_linux_<arch>.tar.gz
cd pwned-check_<version>_linux_<arch>
sudo ./install.sh
```

By default, `install.sh` uses:

- `INSTALL_ROOT=/usr/local/lib/pwned-check`
- `BIN_DIR=/usr/local/bin`

Override locations when needed:

```bash
sudo INSTALL_ROOT=/opt/pwned-check BIN_DIR=/usr/local/bin ./install.sh
```

## Ubuntu 24.04 PAM Walkthrough

Use a disposable VM first and keep an existing privileged shell open while editing PAM. The example below uses the packaged install layout on Ubuntu 24.04.

1. Install and verify the package:

   ```bash
   tar -xzf pwned-check_<version>_linux_amd64.tar.gz
   cd pwned-check_<version>_linux_amd64
   sha256sum -c ../pwned-check_<version>_linux_amd64.tar.gz.sha256
   sudo ./install.sh
   /usr/local/bin/pwned-check --version
   /usr/local/bin/pwned-check-pam-helper --version
   ```

2. Smoke test rejection without PAM:

   ```bash
   printf 'password\n' | sudo /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check --timeout 3s
   echo $?
   ```

   Expected result: exit code `1` with `event=pam_helper_result result=reject reason=pwned`.

3. Back up the PAM password stack:

   ```bash
   sudo cp /etc/pam.d/common-password /etc/pam.d/common-password.pwned-check.bak
   ```

4. Add this line before the `pam_unix.so` password line in `/etc/pam.d/common-password`:

   ```text
   password requisite pam_exec.so expose_authtok quiet /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check --timeout 3s
   ```

5. Test with a dedicated non-production user:

   ```bash
   sudo passwd <test-user>
   ```

   Use `password` as the candidate and confirm the change is rejected. Then retry with a strong random value and confirm the normal password-change flow continues.

6. Roll back immediately if password changes behave unexpectedly:

   ```bash
   sudo cp /etc/pam.d/common-password.pwned-check.bak /etc/pam.d/common-password
   sudo passwd <test-user>
   ```

   Keep the privileged shell open until the rollback test reaches the normal password-change flow. If fail-closed provider outages are the issue, switching to fail-open can restore availability, but restoring the PAM backup is the safest emergency recovery.

## Manual Install Shape

After downloading and verifying a release artifact:

```bash
sudo mkdir -p /usr/local/lib/pwned-check
sudo install -m 0755 pwned-check_linux_amd64 /usr/local/lib/pwned-check/pwned-check_<version>_linux_amd64
sudo install -m 0755 pwned-check-pam-helper_linux_amd64 /usr/local/lib/pwned-check/pwned-check-pam-helper_<version>_linux_amd64
sudo ln -sfn /usr/local/lib/pwned-check/pwned-check_<version>_linux_amd64 /usr/local/lib/pwned-check/current
sudo ln -sfn /usr/local/lib/pwned-check/pwned-check-pam-helper_<version>_linux_amd64 /usr/local/lib/pwned-check/current-pam-helper
sudo ln -sfn /usr/local/lib/pwned-check/current /usr/local/bin/pwned-check
sudo ln -sfn /usr/local/lib/pwned-check/current-pam-helper /usr/local/bin/pwned-check-pam-helper
/usr/local/bin/pwned-check --version
/usr/local/bin/pwned-check-pam-helper --version
```

Replace `<version>` and architecture with the release artifact being installed.

## Upgrade

1. Download the new release artifact.
2. Verify its checksum.
3. Install it under `/usr/local/lib/pwned-check/`.
4. Update `current`.
5. Confirm `/usr/local/bin/pwned-check --version`.
6. Run the mocked binary smoke test where practical.
7. Confirm the PAM helper invokes the intended checker path.

## Rollback

List retained versions:

```bash
ls -1 /usr/local/lib/pwned-check/pwned-check_*_linux_*
```

Activate a previous version:

```bash
sudo ln -sfn /usr/local/lib/pwned-check/<previous-binary> /usr/local/lib/pwned-check/current
sudo ln -sfn /usr/local/lib/pwned-check/<previous-helper-binary> /usr/local/lib/pwned-check/current-pam-helper
/usr/local/bin/pwned-check --version
/usr/local/bin/pwned-check-pam-helper --version
```

## PAM Rollback Principle

PAM rollback instructions must include:

- how to disable the pwned-check PAM line
- how to restore the previous PAM file
- how to test `passwd` after rollback
- how to avoid locking administrators out of password-change workflows

## PAM Helper Exit Mapping

The PAM helper rejects password changes for more than only known-pwned passwords:

| Checker exit | Meaning | Helper result |
|---|---|---|
| `0` | clean, or provider failure when checker fail-open is configured | allow |
| `1` | pwned password | reject |
| `2` | checker usage/configuration error | reject |
| `3` | checker provider/network error in fail-closed mode | reject |
| timeout | checker exceeded helper timeout | reject |

This means fail-closed provider outages and checker configuration mistakes are deliberately conservative at the PAM boundary.

The helper reads at most 4096 bytes by default. Use `--max-bytes <n>` only if your PAM stack has a documented reason to pass longer tokens; the helper rejects values above 1048576 bytes and should not be treated as an arbitrary stream reader.

## Configuration

Environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` for production use; `local` is reserved for tests
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the test-only local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

For production PAM integration, prefer explicit configuration in the integration layer rather than depending on an ambient shell environment.

Before rollout, complete the [Deployment security checklist](deployment-security-checklist.md). For operational failure diagnosis, use [Operational troubleshooting](troubleshooting.md).
