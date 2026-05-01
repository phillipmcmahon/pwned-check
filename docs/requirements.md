# Requirements

`pwned-check` is a password-change enforcement helper. It checks a candidate password against the live Have I Been Pwned Pwned Passwords range API.

## Production Platform

The first production-shaped target is Linux password-change integration.

Initial production assumptions:

- Linux host with PAM-based password-change flow.
- Native `pwned-check` binary available on the host.
- Native `pwned-check-pam-helper` binary available on the host for the first PAM PoC.
- PAM integration invokes the helper through stdin, not command-line arguments.
- Production provider access uses the live public HIBP range API.
- Provider outage behavior is controlled by explicit fail-open/fail-closed configuration.
- The integration layer enforces a hard timeout.

## Production Provider

Production password-change paths use the live HIBP Pwned Passwords range API.

Operational implications:

- hosts must be able to reach the HIBP range endpoint during password changes
- deployments must choose fail-open or fail-closed behavior before rollout
- provider and helper timeouts must be short and explicit
- automated validation must mock HIBP-compatible range responses rather than calling the live service

Offline cache or mirror providers are not part of the current production scope, but the checker design should keep provider concerns isolated so those modes can be considered later without changing the PAM integration contract.

See [Provider policy](provider-policy.md) for current live HIBP configuration, failure posture, and test-provider boundaries.

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

The optional count threshold contract is:

```text
candidate password over stdin -> pwned-check --stdin --min-count <n> -> exit code
```

`--min-count` defaults to `1`. The checker returns exit code `1` only when the provider breach count is greater than or equal to the threshold.

Exit codes:

- `0`: password accepted, or provider failure when fail-open is configured
- `1`: password appears in the breach corpus at or above the configured threshold and should be rejected
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
