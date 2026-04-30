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
pwned-check 0.2.0
```

## Check a Known Pwned Password

```bash
printf 'password\n' | dist/pwned-check --stdin
echo $?
```

Expected result:

- stderr includes `prefix=5BAA6 pwned=true`
- exit code is `1`

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
