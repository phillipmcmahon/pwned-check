# pwned-check

Small Go CLI that checks a supplied password against the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) Pwned Passwords range API using k-anonymity. Only the first 5 chars of the SHA-1 hash are sent to the provider.

The current target is Linux password-change integration. The project supports both the original `pam_exec.so expose_authtok` helper path and an optional native Linux PAM module, `pam_pwned_check.so`, that invokes the same checker contract with a hard timeout.

macOS and Windows integration are intentionally deferred until their signing and platform-security requirements can be handled deliberately rather than worked around.

## Features

- Any-hit rejection policy by default, with optional `--min-count <n>` thresholding
- Fail-open by default, with configurable fail-closed behavior
- HIBP range API provider
- HIBP-compatible local range service provider for automated tests only
- Logs only the 5-character hash prefix, result, count, and configured minimum count
- Single native binary with no Python runtime dependency

## Usage

```
echo -n 'password' | pwned-check --stdin
echo $?
```

## Contract

Input:
- `--stdin` reads one password from standard input.
- `--min-count <n>` rejects only when the breach count is at least `n`; default is `1`.
- stdin input is bounded to 4096 bytes.

Exit codes:
- `0`: clean, or provider failure when fail-open is enabled
- `1`: pwned password at or above the configured threshold
- `2`: config or usage error
- `3`: provider/network error when fail-closed is enabled

Logging:
- The password is never logged.
- Logs contain an event name, the 5-character hash prefix, pwned outcome, count, and minimum count.

Version:
```
pwned-check --version
```

The project does not promise backwards compatibility while the concept is being shaped. The CLI stdin, exit-code, and safe logging contracts are expected to stabilize at `v1.0.0`.

## Configuration

Environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` for production; `local` for automated tests
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the test-only local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

## Development

```
go test ./...
go vet ./...
go build -o dist/pwned-check ./cmd/pwned-check
go run ./scripts/smoke_binary.go dist/pwned-check
```

## Documentation

- [Checker contract](docs/checker-contract.md)
- [Documentation index](docs/README.md)

## Linux Integration Direction

Linux integration is intentionally checker-centered:

1. Keep `pwned-check --stdin` as the simple enforcement contract, with documented policy flags such as `--min-count`.
2. Use thin PAM integrations that invoke the binary with a strict timeout.
3. Use the live HIBP Pwned Passwords range API for production checks.
4. Use fail-closed or fail-open based on the deployment's risk posture.

The checker is now Go so the deployed artifact can be a small native binary. Future macOS and Windows work can reuse the same checker contract while handling notarization, Authenticode signing, and native hook requirements separately.
