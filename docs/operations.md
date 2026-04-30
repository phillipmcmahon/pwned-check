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

When PAM integration lands, rollback instructions must include:

- how to disable the pwned-check PAM line
- how to restore the previous PAM file
- how to test `passwd` after rollback
- how to avoid locking administrators out of password-change workflows

## Configuration

Environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` or `local`
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

For production PAM integration, prefer explicit configuration in the integration layer rather than depending on an ambient shell environment.
