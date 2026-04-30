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
- release artifact integrity
- PAM or platform integration configuration

## Trust Boundaries

```text
Password-change process
  -> platform integration layer
  -> pwned-check binary
  -> HIBP or local range provider
```

The password is trusted only inside the OS password-change process, integration layer, and checker process memory. It must not cross the provider boundary.

## Password Handling Rules

- Read candidate passwords from stdin only.
- Never accept passwords via command-line arguments.
- Never log plaintext passwords.
- Never persist plaintext passwords to disk.
- Never include plaintext passwords in diagnostics, crash reports, telemetry, or issue examples.
- Keep tests that assert plaintext is not emitted.
- Keep logs structured as safe event records, for example `event=validation prefix=<sha1-prefix> pwned=<bool> count=<n>`.

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

The first Linux PoC uses `pwned-check-pam-helper` for this timeout boundary. The helper reads the PAM-supplied token from stdin and invokes `pwned-check --stdin`; it does not pass the password through argv.

## Live Provider Dependency

Production deployments use the live HIBP Pwned Passwords range API. Each deployment must choose fail-open or fail-closed behavior for provider failures and document that decision before rollout.

Offline cache or mirror providers are future considerations. If added, they must preserve the same no-plaintext, no-full-hash provider boundary and must define their own availability and freshness controls.

## Release Integrity

Release artifacts should include:

- versioned binaries
- SHA256 checksums
- documented build provenance
- signing for macOS and Windows before those platforms become production targets

## Non-Goals

- The checker is not a password strength estimator.
- The checker is not a password manager.
- The checker does not store historical password decisions.
- The current phase does not guarantee backwards compatibility while the concept is being shaped.
