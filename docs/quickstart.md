# Quickstart

This guide validates the current standalone checker. It does not configure PAM yet.

## Build

```bash
go build -o dist/pwned-check ./cmd/pwned-check
```

## Check Version

```bash
dist/pwned-check --version
```

Expected shape:

```text
pwned-check <version>
```

## Check a Known Pwned Password

```bash
printf 'password\n' | dist/pwned-check --stdin
echo $?
```

Expected result:

- stderr includes `event=validation prefix=5BAA6 pwned=true count=<n> min_count=1`
- exit code is `1`

## Check a Threshold

```bash
printf 'password\n' | dist/pwned-check --stdin --min-count 100000000
echo $?
```

Expected result:

- stderr includes `min_count=100000000`
- exit code is `0` if the provider count is below the threshold

## Check a Random Password

```bash
printf 'correct-horse-%s-battery-staple\n' "$(uuidgen)" | dist/pwned-check --stdin
echo $?
```

Expected result:

- exit code is usually `0`
- provider/network failure also exits `0` by default because fail-open is the default

## Fail-Closed Provider Failure

```bash
printf 'password\n' | \
  PWNED_CHECK_PROVIDER=local \
  PWNED_CHECK_LOCAL_URL=http://127.0.0.1:9 \
  PWNED_CHECK_FAIL_CLOSED=true \
  dist/pwned-check --stdin
echo $?
```

Expected result:

- exit code is `3`

## Mocked Binary Smoke Test

```bash
go run ./scripts/smoke_binary.go dist/pwned-check
```

This starts an in-process HIBP-compatible test server and verifies that the binary rejects `password` without logging the plaintext password.

## Next Steps

- Read [Operations](operations.md) for install and rollback guidance.
- For native PAM packages, start with [Install Native PAM From GitHub Releases](operations.md#install-native-pam-from-github-releases).
- Read [Linux PAM PoC](linux-pam-poc.md) before editing PAM helper stacks.
- Read [Deployment security checklist](deployment-security-checklist.md) before enforcing password changes.
