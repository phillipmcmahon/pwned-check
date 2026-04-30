# Testing Guide

The test suite should mirror the current architecture:

```text
CLI -> config -> hash split -> provider -> exit code
```

## Local Validation

Run the default validation gate:

```bash
make validate
```

Equivalent commands:

```bash
gofmt -l .
go test ./...
go vet ./...
go run honnef.co/go/tools/cmd/staticcheck ./...
go build -o dist/pwned-check ./cmd/pwned-check
go run ./scripts/smoke_binary.go dist/pwned-check
./scripts/docker-smoke.sh --platform linux/amd64
./scripts/docker-pam-smoke.sh --platform linux/amd64
make package-linux
```

Install the matching pre-push hook:

```bash
scripts/install-git-hooks.sh
```

The hook runs the same validation gate before `git push`.

## Test Layout

| Area | Focus |
|---|---|
| `internal/pwned/core_test.go` | Hash splitting and provider-agnostic validation |
| `internal/pwned/config_test.go` | Environment configuration defaults and overrides |
| `internal/pwned/provider_test.go` | HIBP/local range response parsing and headers |
| `internal/pwned/cli_test.go` | CLI exit codes, fail-open/fail-closed, logging, and mocked provider flow |
| `internal/pamhelper/helper_test.go` | PAM helper exit mapping, timeout, and no-secret-output behavior |
| `scripts/smoke_binary.go` | Built-binary behavior against a mocked range service |
| `scripts/container-smoke` | In-container Linux binary behavior across distro images |
| `scripts/pam-package-smoke` | In-container package install, `/etc/pam.d` wiring, and PAM allow/reject outcomes through `pam_exec.so expose_authtok` |

## CI Rules

CI should not depend on the live HIBP API. Automated tests use mocked HIBP-compatible range responses.

The GitHub workflow is split into:

- `lint`: gofmt check, `go vet`, and Staticcheck
- `test`: race-enabled Go tests
- `smoke`: built-binary smoke, Docker distro smoke, and Docker PAM package smoke
- `cross-build`: artifact builds gated on lint, test, and smoke

Release-sensitive checks:

- CLI exit-code behavior
- no plaintext password in output
- stable safe log event shape
- mocked HIBP-compatible provider contract
- provider timeout/failure behavior
- binary smoke test
- Docker smoke matrix across Debian, Ubuntu, Alpine, Arch Linux, and Fedora
- Docker PAM package smoke across Debian, Ubuntu, Alpine, Arch Linux, and Fedora
- Linux package build for `amd64` and `arm64` with SHA256 files

## Linux Integration Testing

The PAM package smoke path proves:

- known pwned password is rejected
- clean password is accepted
- provider failure follows fail-open/fail-closed configuration
- child process timeout blocks hangs
- package installation creates stable binary and symlink paths
- a dedicated `/etc/pam.d/pwned-check-smoke` service can pass the candidate token to the helper

The automated PAM smoke uses an isolated PAM `auth` service to drive token exposure deterministically in containers. The operator-facing password-change placement remains the Linux PAM PoC path and should be manually tested before enabling it on a host.

## Static Analysis

Staticcheck is pinned through Go module metadata and runs in both local validation and CI:

```bash
go run honnef.co/go/tools/cmd/staticcheck ./...
```
