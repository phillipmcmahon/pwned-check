# Requirements

`pwned-check` is a password-change enforcement checker. It checks a candidate password against the live Have I Been Pwned Pwned Passwords range API.

## Production Platform

The production-shaped target is Linux password-change integration through native PAM packages.

Initial production assumptions:

- Linux host with PAM-based password-change flow.
- Native `pwned-check` binary installed by the distro package.
- `pam_pwned_check.so` installed by the native PAM package.
- Package enablement commands available for dry-run, enforcement, disable, and rollback.
- PAM integration passes the candidate through stdin or `PAM_AUTHTOK`, not command-line arguments.
- Production provider access uses the live public HIBP range API.
- Provider outage behavior is controlled by explicit fail-open/fail-closed configuration.
- The integration layer enforces a hard timeout.

## Production Provider

Production password-change paths use the live HIBP Pwned Passwords range API.

Operational implications:

- hosts must be able to reach the HIBP range endpoint during password changes
- deployments must choose fail-open or fail-closed behavior before rollout
- provider and native module timeouts must be short and explicit
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

The stable checker contract is documented in [Checker contract](checker-contract.md). In short, integrations pass the candidate password over stdin to `pwned-check --stdin`, optionally add `--min-count <n>`, and make policy decisions only from the documented exit code.

## Build Requirements

Development and release validation require:

- Go 1.26
- GitHub CLI for release monitoring and release asset retrieval
- `jq` for GitHub workflow status helpers
- optional Staticcheck for local validation

## Security Requirements

- Do not pass plaintext passwords through argv.
- Do not log plaintext passwords.
- Do not write plaintext passwords to disk.
- Do not include plaintext passwords in telemetry or diagnostics.
- Use hard timeouts around provider and integration calls.
- Document fail-open/fail-closed posture for each deployment.
