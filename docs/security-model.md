# Security Model

`pwned-check` operates in a sensitive path: password change. The project intentionally keeps the checker contract small so secret handling and failure modes stay reviewable.

## Assets

Primary assets:

- candidate plaintext password
- local authentication workflow availability
- integrity of the password rejection decision
- operator trust in logs and audit output

Secondary assets:

- live HIBP range API availability
- release package integrity
- PAM or platform integration configuration

## Trust Boundaries

```text
Password-change process
  -> native Linux PAM module
  -> pwned-check binary
  -> live HIBP range API
```

The password is trusted only inside the OS password-change process, native PAM
module memory, checker process memory, and kernel pipes between those processes.
It must not cross the provider boundary.

Packaged enable, enforce, disable, and rollback scripts are configuration
helpers only. They edit distro-managed PAM configuration and must never receive
candidate passwords.

## Password Handling Rules

- Read candidate passwords from stdin or PAM-owned token APIs only.
- Bound password reads to 4096 bytes in the checker and supported PAM integration paths.
- Never accept passwords via command-line arguments.
- Never log plaintext passwords.
- Never persist plaintext passwords to disk.
- Never include plaintext passwords in diagnostics, crash reports, telemetry, or issue examples.
- Keep tests that assert plaintext is not emitted.
- Keep logs structured as safe event records, for example `event=validation prefix=<sha1-prefix> pwned=<bool> count=<n> min_count=<n>`.

See [Logging policy](logging-policy.md) for the current event catalog and safe rollout counters.

## Provider Privacy

The checker computes a SHA-1 hash of the candidate password and splits it:

- first 5 hex characters: sent to the provider
- remaining suffix: matched locally against provider response

This follows the HIBP range API k-anonymity model. The full hash and plaintext password are not sent to HIBP.

## Failure Modes

Fail-open:

- provider failures allow password change
- protects account-management availability
- weakens enforcement during provider outage

Fail-closed:

- provider failures reject or block password change
- protects enforcement
- can interrupt account-management workflows during outage

Each deployment must choose and document its posture.

## Timeout Controls

Provider and integration timeouts are mandatory. Password-change workflows must not hang indefinitely because a provider, network path, or child process stalls.

The PAM integration should enforce its own timeout around the checker process even though the checker also has provider timeouts.

The native PAM module enforces a timeout around the checker process. It reads the PAM-supplied token from `PAM_AUTHTOK`; when `PAM_AUTHTOK` is absent, it uses Linux PAM's `pam_get_authtok` API so PAM performs the normal password conversation. The checker is invoked without passing the password through argv.

## Process and Environment Exposure

The checker and native module checker child are short-lived in normal operation, so plaintext candidates exist in process memory only for the duration of one validation. The native module keeps its PAM token copy in zeroizing memory, but transient copies can still exist in PAM-owned memory, the checker process, and kernel pipe buffers. Core dump hardening such as `prctl(PR_SET_DUMPABLE, 0)` is not implemented in the current native module; any future native-module dump suppression must account for the process-wide side effect.

The native module starts the checker with a clean environment. Environment values must not contain plaintext passwords or full hashes.

Integration argv is safe by design: it contains only module flags, checker path, and timeout values. Candidate passwords are passed through PAM token memory or stdin, never argv, so they should not appear in process listings.

## Live Provider Dependency

Production deployments use the live HIBP Pwned Passwords range API. Each deployment must choose fail-open or fail-closed behavior for provider failures and document that decision before rollout.

Offline cache or mirror providers are future considerations. If added, they must preserve the same no-plaintext, no-full-hash provider boundary and must define their own availability and freshness controls.

## Release Integrity

Release packages should include:

- versioned binaries
- SHA256 checksums
- documented build provenance
- signed package repository metadata for supported Linux package families
- signing for macOS and Windows before those platforms become production targets

## Non-Goals

- The checker is not a password strength estimator.
- The checker is not a password manager.
- The checker does not store historical password decisions.
