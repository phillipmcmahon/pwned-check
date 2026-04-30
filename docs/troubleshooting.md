# Operational Troubleshooting

This guide maps common rollout symptoms to safe diagnostics and likely fixes.

## Checker Exit Codes

| Exit code | Meaning | Operator action |
|---|---|---|
| `0` | Password accepted, or provider failure in fail-open mode. | Check stderr events to distinguish clean from fail-open provider failure. |
| `1` | Password appears in the breach corpus. | Expected rejection. Confirm no plaintext was logged. |
| `2` | Usage or configuration error. | Check environment variables and command flags. |
| `3` | Provider or network error in fail-closed mode. | Check HIBP reachability, DNS, proxy/firewall rules, and timeout values. |

## PAM Helper Symptoms

| Log event | Meaning | Operator action |
|---|---|---|
| `event=pam_helper_result result=allow` | Password-change flow can continue. | No action unless this appears during expected rejection tests. |
| `event=pam_helper_result result=reject reason=pwned` | Candidate was found in the breach corpus. | Expected for known pwned test passwords. |
| `event=pam_helper_failure reason=timeout` | Checker exceeded helper timeout. | Increase helper timeout only after checking provider timeout and network behavior. |
| `event=pam_helper_failure reason=checker_config` | Checker configuration is invalid. | Validate provider, endpoint, timeout, and fail-closed environment. |
| `event=pam_helper_failure reason=checker_provider` | Checker hit provider failure in fail-closed mode. | Confirm live HIBP reachability or switch to fail-open if availability is the priority. |
| `event=pam_helper_failure reason=checker_exit` | Checker returned an unexpected code. | Capture version and command configuration, then investigate as a defect. |

## Common Checks

Confirm binaries:

```bash
/usr/local/bin/pwned-check --version
/usr/local/bin/pwned-check-pam-helper --version
```

Check live HIBP reachability from the host:

```bash
curl -fsS https://api.pwnedpasswords.com/range/5BAA6 >/dev/null
```

Check fail-open behavior:

```bash
printf 'password\n' | \
  PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/ \
  PWNED_CHECK_FAIL_CLOSED=false \
  /usr/local/bin/pwned-check --stdin
echo $?
```

Expected exit code: `0` with `event=provider_failure fail_closed=false`.

Check fail-closed behavior:

```bash
printf 'password\n' | \
  PWNED_CHECK_HIBP_ENDPOINT=http://127.0.0.1:9/range/ \
  PWNED_CHECK_FAIL_CLOSED=true \
  /usr/local/bin/pwned-check --stdin
echo $?
```

Expected exit code: `3` with `event=provider_failure fail_closed=true`.

## Safe Escalation Data

When opening an issue, include:

- binary versions
- OS and distro version
- relevant environment variable names and non-secret values
- exit code
- safe `event=...` log lines
- whether fail-open or fail-closed was selected

Do not include plaintext passwords, full hashes, hash suffixes, account passwords, or production PAM files containing unrelated local policy.
