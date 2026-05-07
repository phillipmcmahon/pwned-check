# Checker Contract

The stable checker contract is stdin in, exit code out:

```text
candidate password over stdin -> pwned-check --stdin -> exit code
```

The optional count threshold contract is:

```text
candidate password over stdin -> pwned-check --stdin --min-count <n> -> exit code
```

`--min-count` defaults to `1`. The checker returns exit code `1` only when the provider breach count is greater than or equal to the threshold.

| Exit code | Meaning |
|---|---|
| `0` | Password accepted, or provider-availability failure when fail-open is configured. |
| `1` | Password appears in the breach corpus at or above the configured threshold and should be rejected. |
| `2` | Usage or configuration error. |
| `3` | Provider or network error when fail-closed is configured. |

Fail-open provider-availability failures short-circuit count-based policy: if
the provider cannot return a breach count and fail-open is configured, the
checker exits `0` regardless of `--min-count`. In the native PAM module,
fail-open also covers the module timeout while waiting for the checker, because
a host without provider connectivity can time out before the checker returns an
explicit provider-error exit code.

Callers must not parse checker stderr for policy decisions. Stderr is structured diagnostic output only.
