# pwned-check

Linux password-change protection backed by the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) Pwned Passwords range API. The native PAM package rejects known-breached passwords during password changes while keeping the provider HTTP logic in the unprivileged `pwned-check` checker binary.

Only the first 5 characters of the password's SHA-1 hash are sent to the provider.

## Quick Install

Native Linux PAM packages are the production-supported install path as of
v0.3.0. Packages are available for Debian/Ubuntu, Fedora/RHEL/Rocky, Arch
Linux, and Alpine Linux-PAM through signed package repositories. The production
gate evidence is recorded in
[v0.3.0 production gate evidence](docs/releases/v0.3.0-production-gate.md).

Start with the [Linux package install guide](docs/linux-install.md). It covers
repository setup, package installation, dry-run, enforcement, rollback, removal,
and emergency recovery in one place.

| Platform | Install instructions |
|---|---|
| Debian/Ubuntu | [Linux package install](docs/linux-install.md#debian-or-ubuntu) |
| Fedora/RHEL/Rocky | [Linux package install](docs/linux-install.md#fedora-rhel-or-rocky) |
| Arch Linux | [Linux package install](docs/linux-install.md#arch-linux) |
| Alpine Linux-PAM | [Linux package install](docs/linux-install.md#alpine-linux-pam) |

Package installation only places files on disk. Enablement is explicit and should start in dry-run mode:

```
sudo pwned-check-pam-enable-dry-run
sudo journalctl -t pwned-check -n 20 --no-pager
```

After dry-run logs and rollback have been validated, switch to enforcement:

```
sudo pwned-check-pam-enable-enforce
```

Rollback is built into the package commands:

```
sudo pwned-check-pam-disable
```

Use [Operations](docs/operations.md) as the deeper runbook when planning a
production rollout.

## Standalone Checker

The package also installs the `pwned-check` CLI. You can test the checker directly:

```
printf 'password\n' | pwned-check --stdin
echo $?
```

Exit codes:
- `0`: clean, or provider failure when fail-open is enabled
- `1`: pwned password at or above the configured threshold
- `2`: configuration or usage error
- `3`: provider/network error when fail-closed is enabled

Useful options:

```
pwned-check --version
pwned-check --stdin --min-count 10
```

The checker contract is documented in [Checker contract](docs/checker-contract.md).

## Features

- Native Linux PAM module package for password-change enforcement
- Signed package repositories for Debian/Ubuntu, Fedora/RHEL/Rocky, Arch Linux, and Alpine Linux-PAM
- Dry-run, enforcement, disable, and rollback commands
- Any-hit rejection policy by default, with optional `--min-count <n>` thresholding
- Fail-open by default, with configurable fail-closed behavior
- HIBP range API provider using k-anonymity
- Safe logs that exclude plaintext passwords, full hashes, and hash suffixes
- Single native checker binary with no Python runtime dependency

## Configuration

Checker environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` for production; `local` for automated tests
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the test-only local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

For production PAM integration, prefer package defaults or explicit PAM module configuration over ambient shell environment.

## Documentation

| Need | Start here |
|---|---|
| Install, enable, roll back, or remove the native PAM package | [Linux package install](docs/linux-install.md) |
| Plan production operations | [Operations](docs/operations.md) |
| Review signed repository internals | [Package repositories](docs/package-repositories.md) |
| Prepare a secure rollout | [Deployment security checklist](docs/deployment-security-checklist.md) |
| Diagnose rollout issues | [Troubleshooting](docs/troubleshooting.md) |
| Understand checker stdin and exit codes | [Checker contract](docs/checker-contract.md) |
| Review all docs | [Documentation index](docs/README.md) |

## Development

```
go test ./...
go vet ./...
go build -o dist/pwned-check ./cmd/pwned-check
go run ./scripts/smoke_binary.go dist/pwned-check
```

Maintainer validation and release procedures are covered in [Testing](docs/testing.md) and [Release playbook](docs/release-playbook.md).

macOS and Windows integration are intentionally deferred until their signing and platform-security requirements can be handled deliberately.
