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

## CI Rules

CI should not depend on the live HIBP API. Automated tests use mocked HIBP-compatible range responses.

The GitHub workflow is split into:

- `lint`: gofmt check, `go vet`, and Staticcheck
- `test`: race-enabled Go tests
- `smoke`: built-binary smoke and Docker distro smoke
- `cross-build`: artifact builds gated on lint, test, and smoke

Release-sensitive checks:

- CLI exit-code behavior
- no plaintext password in output
- stable safe log event shape
- local provider contract
- provider timeout/failure behavior
- binary smoke test
- Docker smoke matrix across Debian, Ubuntu, Alpine, Arch Linux, and Fedora
- Linux package build for `amd64` and `arm64` with SHA256 files

## Linux Integration Testing

When PAM work starts, add a Linux integration test path that proves:

- known pwned password is rejected
- clean password is accepted
- provider failure follows fail-open/fail-closed configuration
- child process timeout blocks hangs
- rollback instructions restore password-change behavior

## Static Analysis

Staticcheck is pinned through Go module metadata and runs in both local validation and CI:

```bash
go run honnef.co/go/tools/cmd/staticcheck ./...
```
