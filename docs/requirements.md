# Requirements

`pwned-check` is a password-change enforcement helper. It checks a candidate password against the Have I Been Pwned Pwned Passwords range API or a compatible local mirror.

## Production Platform

The first production-shaped target is Linux password-change integration.

Initial production assumptions:

- Linux host with PAM-based password-change flow.
- Native `pwned-check` binary available on the host.
- Native `pwned-check-pam-helper` binary available on the host for the first PAM PoC.
- PAM integration invokes the helper through stdin, not command-line arguments.
- Provider access is either:
  - the public HIBP range API, or
  - an internal HIBP-compatible range mirror.
- The integration layer enforces a hard timeout.

## Preferred Production Provider

Production password-change paths should prefer a local HIBP-compatible mirror when possible.

Why:

- avoids direct internet dependency during password changes
- reduces latency variance
- keeps provider availability under operator control
- avoids policy issues around servers making external calls from authentication paths

The public HIBP provider remains useful for development, small deployments, and controlled environments where external lookup is acceptable.

## Non-Production Platforms

macOS and Windows are intentionally deferred.

They remain future targets, but production-shaped work must address:

- macOS code signing and notarization
- Windows Authenticode signing
- Windows Password Filter DLL safety and LSASS constraints
- platform-specific rollback and recovery

Do not reduce host security posture to make early integration easier.

## Runtime Contract

The stable checker contract is:

```text
candidate password over stdin -> pwned-check --stdin -> exit code
```

Exit codes:

- `0`: password accepted, or provider failure when fail-open is configured
- `1`: password appears in the breach corpus and should be rejected
- `2`: usage or configuration error
- `3`: provider/network error when fail-closed is configured

## Build Requirements

Development and release validation require:

- Go 1.26
- GitHub CLI for project-board automation
- `jq` for project-board scripts
- optional Staticcheck for local validation

## Security Requirements

- Do not pass plaintext passwords through argv.
- Do not log plaintext passwords.
- Do not write plaintext passwords to disk.
- Do not include plaintext passwords in telemetry or diagnostics.
- Use hard timeouts around provider and integration calls.
- Document fail-open/fail-closed posture for each deployment.
