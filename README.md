# pwned-check

Small Go CLI that checks a supplied password against the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) Pwned Passwords range API using k-anonymity. Only the first 5 chars of the SHA-1 hash are sent to the provider.

The near-term target is Linux password-change integration. The first PoC uses `pam_exec.so expose_authtok` to pipe a candidate password to `pwned-check-pam-helper`, which invokes `pwned-check --stdin` with a hard timeout.

macOS and Windows integration are intentionally deferred until the Linux flow is proven, because their signing and platform-security requirements should be handled deliberately rather than worked around.

## Features

- Any-hit rejection policy
- Fail-open by default, with configurable fail-closed behavior
- HIBP range API provider
- HIBP-compatible local range service provider for tests or internal mirrors
- Logs only the 5-character hash prefix, result, and count
- Single native binary with no Python runtime dependency

## Usage

```
echo -n 'password' | pwned-check --stdin
echo $?
```

## Contract

Input:
- `--stdin` reads one password from standard input.

Exit codes:
- `0`: clean, or provider failure when fail-open is enabled
- `1`: pwned password
- `2`: config or usage error
- `3`: provider/network error when fail-closed is enabled

Logging:
- The password is never logged.
- Logs contain an event name, the 5-character hash prefix, pwned outcome, and count.

Version:
```
pwned-check --version
```

## Configuration

Environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` or `local`
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the local provider
- `PWNED_CHECK_HIBP_ENDPOINT`: override HIBP endpoint for controlled tests

## Development

```
go test ./...
go vet ./...
go build -o dist/pwned-check ./cmd/pwned-check
go run ./scripts/smoke_binary.go dist/pwned-check
```

## Linux Integration Direction

The first production-shaped integration should be Linux-first:

1. Keep `pwned-check --stdin` as the simple enforcement contract.
2. Add a small PAM integration that invokes the binary with a strict timeout.
3. Prefer a local HIBP-compatible mirror for production password-change paths.
4. Use fail-closed or fail-open based on the deployment's risk posture.

The checker is now Go so the deployed artifact can be a small native binary. Future macOS and Windows work can reuse the same checker contract while handling notarization, Authenticode signing, and native hook requirements separately.
