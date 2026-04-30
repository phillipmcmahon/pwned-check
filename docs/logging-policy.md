# Logging Policy

`pwned-check` logs must be useful for audit and rollout validation without exposing secrets.

## Rules

- Never log plaintext passwords.
- Never log full SHA-1 hashes or hash suffixes.
- Never log command-line arguments that may contain secrets.
- Log only stable event names and bounded fields.
- Keep logs on stderr so stdout remains available for explicit command output such as `--version`.

## Checker Events

| Event | Meaning | Fields |
|---|---|---|
| `event=validation` | Provider lookup completed and the candidate was evaluated. | `prefix`, `pwned`, `count` |
| `event=provider_failure` | Provider lookup failed or timed out. | `fail_closed`, `error` |

`prefix` is the first five hex characters of the candidate password SHA-1 hash. It is expected to be visible in logs because it is also the material sent to HIBP. The suffix and plaintext password must never appear.

## PAM Helper Events

| Event | Meaning | Fields |
|---|---|---|
| `event=pam_helper_result result=allow` | Checker allowed the password. | none |
| `event=pam_helper_result result=reject reason=pwned` | Checker found the password in the breach corpus. | `reason` |
| `event=pam_helper_failure reason=timeout` | Checker exceeded helper timeout. | `timeout` |
| `event=pam_helper_failure reason=checker_config` | Checker returned a configuration error. | `reason` |
| `event=pam_helper_failure reason=checker_provider` | Checker returned a provider error in fail-closed mode. | `reason` |
| `event=pam_helper_failure reason=checker_exit` | Checker returned an unexpected exit code. | `code` |

## Rollout Diagnostics

During rollout, operators can count safe event fields:

- `event=validation pwned=true`
- `event=validation pwned=false`
- `event=provider_failure fail_closed=false`
- `event=provider_failure fail_closed=true`
- `event=pam_helper_failure reason=timeout`
- `event=pam_helper_failure reason=checker_provider`

Do not add user identifiers, host account names, plaintext candidates, or full hashes to these event lines.
