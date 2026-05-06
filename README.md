# pwned-check

`pwned-check` blocks known-breached passwords during Linux password changes.
The supported integration is the native Linux PAM package installed from the
signed package repositories.

Only the first 5 characters of the password's SHA-1 hash are sent to the Have I
Been Pwned Pwned Passwords range API. Plaintext passwords, full hashes, and hash
suffixes are not logged.

## Install

Start here:

- [Linux install and operations guide](docs/linux-install.md)

That guide covers repository setup, package installation, dry-run, enforcement,
rollback, removal, and the standalone CLI.

Supported package repositories:

| Platform | Architectures |
|---|---|
| Debian/Ubuntu | `amd64`, `arm64` |
| Fedora/RHEL/Rocky | `x86_64`, `aarch64` |
| Arch Linux | `x86_64` |
| Alpine Linux-PAM | `x86_64`, `aarch64` |

Package installation does not change PAM. Enablement is explicit and should
start in dry-run mode:

```bash
sudo pwned-check-pam-enable-dry-run
sudo journalctl -t pwned-check -n 20 --no-pager
```

After dry-run logs and rollback have been validated, switch to enforcement:

```bash
sudo pwned-check-pam-enable-enforce
```

Rollback is built into the package commands:

```bash
sudo pwned-check-pam-disable
```

## CLI

The package also installs the standalone checker:

```bash
printf 'password\n' | pwned-check --stdin
echo $?
```

Exit codes are defined in [Checker contract](docs/checker-contract.md).

## Documentation

| Need | Start here |
|---|---|
| Install, enable, roll back, remove, or troubleshoot | [Linux install and operations guide](docs/linux-install.md) |
| Understand repository signing and publication | [Package repositories](docs/package-repositories.md) |
| Understand checker stdin and exit codes | [Checker contract](docs/checker-contract.md) |
| Review security boundaries | [Security model](docs/security-model.md) |
| Review all maintained docs | [Documentation index](docs/README.md) |

Maintainer validation and release procedures are covered in
[Testing](docs/testing.md), [Distro testing](docs/distro-testing.md), and
[Release playbook](docs/release-playbook.md).

## Development

```bash
go test ./...
go vet ./...
go build -o dist/pwned-check ./cmd/pwned-check
go run ./scripts/smoke_binary.go dist/pwned-check
```

macOS and Windows integrations are intentionally deferred until their signing
and platform-security requirements can be handled deliberately.
