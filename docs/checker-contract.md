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
| `0` | Password accepted, or provider failure when fail-open is configured. |
| `1` | Password appears in the breach corpus at or above the configured threshold and should be rejected. |
| `2` | Usage or configuration error. |
| `3` | Provider or network error when fail-closed is configured. |

Fail-open provider failures short-circuit count-based policy: if the provider cannot return a breach count and fail-open is configured, the checker exits `0` regardless of `--min-count`.

Callers must not parse checker stderr for policy decisions. Stderr is structured diagnostic output only.
