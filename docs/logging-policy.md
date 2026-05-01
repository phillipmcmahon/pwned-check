# Logging Policy

`pwned-check` logs must be useful for audit and rollout validation without exposing secrets.

## Rules

- Never log plaintext passwords.
- Never log full SHA-1 hashes or hash suffixes.
- Never log command-line arguments that may contain secrets.
- Log only stable event names and bounded fields.
- Keep logs on stderr so stdout remains available for explicit command output such as `--version`.

## Safe Strings

User-facing conversation messages must be checked in as constants and covered by log-safety fixtures before they are used by a PAM integration. The current approved messages are:

```text
This password appears in a known breach corpus. Choose a different password.
Password breach check failed. Try again later or contact your administrator.
```

Tests must assert these exact strings can be emitted to the PAM conversation layer without appearing in checker argv, checker stdin diagnostics, structured log fields, provider requests, or metrics labels.

## Checker Events

| Event | Meaning | Fields |
|---|---|---|
| `event=validation` | Provider lookup completed and the candidate was evaluated. | `prefix`, `pwned`, `count`, `min_count` |
| `event=provider_failure` | Provider lookup failed or timed out. | `fail_closed`, `error` |

`prefix` is the first five hex characters of the candidate password SHA-1 hash. It is expected to be visible in logs because it is also the material sent to HIBP. The suffix and plaintext password must never appear.

Example checker logs:

```text
2026-04-30 17:00:00 event=validation prefix=5BAA6 pwned=true count=123 min_count=1
2026-04-30 17:00:00 event=provider_failure fail_closed=true error="Get \"https://api.pwnedpasswords.com/range/5BAA6\": context deadline exceeded"
```

## PAM Helper Events

| Event | Meaning | Fields |
|---|---|---|
| `event=pam_helper_result result=allow` | Checker allowed the password. | none |
| `event=pam_helper_result result=reject reason=pwned` | Checker found the password in the breach corpus. | `reason` |
| `event=pam_helper_failure reason=timeout` | Checker exceeded helper timeout. | `timeout` |
| `event=pam_helper_failure reason=checker_config` | Checker returned a configuration error. | `reason` |
| `event=pam_helper_failure reason=checker_provider` | Checker returned a provider error in fail-closed mode. | `reason` |
| `event=pam_helper_failure reason=checker_exit` | Checker returned an unexpected exit code. | `code` |

The helper may include a bounded `checker_stderr` excerpt for checker configuration, provider, or unexpected-exit failures. The checker must never write plaintext passwords to stderr, and the helper limits this excerpt to keep diagnostics safe and manageable.

Example helper logs:

```text
event=pam_helper_result result=reject reason=pwned
event=pam_helper_failure reason=checker_provider checker_stderr="2026-04-30 17:00:00 event=provider_failure fail_closed=true error=\"provider returned HTTP 503\""
```

## Native PAM Module Events

The native Linux PAM module emits structured events through syslog with the stable identifier `pwned-check`.

| Event | Meaning | Fields |
|---|---|---|
| `event=pam_module_result result=allow` | Checker allowed the password. | none |
| `event=pam_module_result result=reject reason=pwned` | Checker found the password in the breach corpus. | `reason` |
| `event=pam_module_result result=allow mode=dry_run would=reject reason=pwned` | Dry-run mode observed a would-be rejection but allowed the password change. | `mode`, `would`, `reason` |
| `event=pam_module_failure reason=module_config` | The module rejected invalid PAM stack arguments. | `reason` |
| `event=pam_module_failure reason=checker_config code=2` | Checker returned a configuration error. | `reason`, `code` |
| `event=pam_module_failure reason=checker_provider code=3` | Checker returned a provider error in fail-closed mode. | `reason`, `code` |
| `event=pam_module_failure reason=timeout timeout=3s` | Checker exceeded the module timeout. | `reason`, `timeout` |
| `event=pam_module_failure reason=exec` | The module could not execute the checker. | `reason` |
| `event=pam_module_failure reason=checker_exit code=9` | Checker returned an unexpected exit code. | `reason`, `code` |
| `event=pam_module_failure reason=missing_authtok` | PAM did not provide a usable password token to the module. | `reason` |
| `event=pam_module_config timeout=3s fail_policy=fail_open dry_run=false` | Debug-only module configuration summary. | `timeout`, `fail_policy`, `dry_run` |

The debug configuration event must not include the checker path, PAM user, candidate password, hashes, provider response data, or module argv.

Example native module logs:

```text
event=pam_module_result result=reject reason=pwned
event=pam_module_failure reason=timeout timeout=3s
event=pam_module_result result=allow mode=dry_run would=reject reason=pwned
```

## Rollout Diagnostics

During rollout, operators can count safe event fields:

- `event=validation pwned=true`
- `event=validation pwned=false`
- `event=provider_failure fail_closed=false`
- `event=provider_failure fail_closed=true`
- `event=pam_helper_failure reason=timeout`
- `event=pam_helper_failure reason=checker_provider`
- `event=pam_module_result result=reject reason=pwned`
- `event=pam_module_result result=allow mode=dry_run`
- `event=pam_module_failure reason=timeout`
- `event=pam_module_failure reason=checker_provider`

Do not add user identifiers, host account names, plaintext candidates, or full hashes to these event lines.

## Counter Examples

A log pipeline can derive Prometheus-style counters from event fields without parsing secrets:

```text
pwned_check_validation_total{pwned="true"} 1
pwned_check_validation_total{pwned="false"} 1
pwned_check_provider_failure_total{fail_closed="true"} 1
pwned_check_pam_helper_failure_total{reason="checker_provider"} 1
```

For Vector-style pipelines, parse the key/value event line and increment counters from `.event`, `.pwned`, `.fail_closed`, and `.reason`. Keep `checker_stderr` as a bounded diagnostic field, not as a counter label.

For Promtail/Loki pipelines, prefer labels with low cardinality such as `event`, `pwned`, `fail_closed`, and `reason`. Do not promote `error`, `checker_stderr`, usernames, host account names, hash prefixes, or candidate-derived values into labels.
