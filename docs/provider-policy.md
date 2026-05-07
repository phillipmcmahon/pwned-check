# Provider Policy

This document describes the current provider posture for production and tests.

## Current Production Provider

Production deployments use the live HIBP Pwned Passwords range API.

The checker sends only the first five hexadecimal characters of the candidate password SHA-1 hash to HIBP. The suffix comparison happens locally inside `pwned-check`.

Default endpoint:

```text
https://api.pwnedpasswords.com/range/
```

The endpoint can be overridden with `PWNED_CHECK_HIBP_ENDPOINT` for controlled tests. Production deployments should not override it unless an explicit design decision has approved the alternate provider.

The public HIBP endpoint must use HTTPS. HTTP endpoints are allowed only for controlled non-public test endpoints such as loopback smoke fixtures.

## Provider-Availability Policy

Provider-availability failures are controlled by `PWNED_CHECK_FAIL_CLOSED`.

Fail-open is the default:

```bash
PWNED_CHECK_FAIL_CLOSED=false
```

Provider-availability failures allow the password change and emit a safe `event=provider_failure fail_closed=false` log entry.

Fail-closed rejects provider failures:

```bash
PWNED_CHECK_FAIL_CLOSED=true
```

Provider-availability failures return the provider-failure outcome defined in [Checker contract](checker-contract.md) and are mapped by PAM integrations to password-change rejection.

Choose this setting before rollout and document the decision for each deployment.

## Timeout Posture

Provider calls use `PWNED_CHECK_TIMEOUT`, in seconds. The default is five seconds.

Password-change integrations should also wrap the checker in their own timeout. The native PAM module does this with its `timeout=<seconds>` argument so a stalled checker process cannot hang the PAM stack indefinitely.

The checker enforces provider timeout through both the request context and the HTTP client timeout. A zero or negative provider timeout is invalid, including for test providers constructed directly in code.

## Request Volume and Rate Limiting

The checker performs one HIBP range request per password candidate and does not retry failed provider requests. The HIBP range API is designed for this k-anonymity lookup pattern, but deployments should avoid invoking the checker on every keystroke or in tight retry loops. PAM placement should call the checker once for a submitted candidate password, and repeated provider failures should be investigated through logs rather than retried aggressively.

## Test Provider Boundary

Automated tests must not call the live HIBP API.

Tests use HIBP-compatible mocked range responses. The `local` provider mode exists for test harnesses and deterministic smoke tests; it is not the current production deployment model.

## Future Provider Scope

Offline cache or mirror providers are future considerations. If added, they must preserve:

- the same stdin and exit-code contract
- no plaintext password crossing the provider boundary
- no full SHA-1 hash crossing the provider boundary
- explicit provider-availability policy behavior
- freshness and availability controls for cached or mirrored data
