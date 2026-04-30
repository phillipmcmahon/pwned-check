# pwned-check

Cross-platform CLI that checks a password against the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) Pwned Passwords range API using k-anonymity. Only the first 5 chars of the SHA-1 hash are sent to the provider.

The PoC target is a small executable for macOS and Windows password-change integrations. Future OS hooks should be able to pipe a candidate password to `pwned-check --stdin` and reject the change when the command exits with `1`.

## Features
- Any-hit rejection policy
- Fail-open with warning (configurable fail-closed)
- HIBP range API provider
- HIBP-compatible local range service provider for tests or internal mirrors
- Logs only the 5-char prefix + outcome
- Python 3.14 minimum

## Usage
```
echo -n 'hunter2' | pwned-check --stdin
```

## Contract

Input:
- `--stdin` reads one password from standard input.
- Without `--stdin`, the command prompts with `getpass`.

Exit codes:
- `0`: clean, or provider failure when fail-open is enabled
- `1`: pwned password
- `2`: config or usage error
- `3`: provider/network error when fail-closed is enabled

Logging:
- The password is never logged.
- Logs contain the 5-character hash prefix, pwned outcome, and count.

Version:
```
pwned-check --version
```

## Configuration

Configuration can be supplied with a TOML file passed via `--config`, or by environment variables:

- `PWNED_CHECK_PROVIDER`: `hibp` or `local`
- `PWNED_CHECK_FAIL_CLOSED`: `1`, `true`, or `yes`
- `PWNED_CHECK_TIMEOUT`: request timeout in seconds
- `PWNED_CHECK_LOCAL_URL`: base URL for the local provider

Example local provider smoke test:
```
echo -n 'password' | PWNED_CHECK_PROVIDER=local PWNED_CHECK_LOCAL_URL=http://127.0.0.1:8000 pwned-check --stdin
```

## Development

```
python3 -m venv .venv
. .venv/bin/activate
pip install -e ".[dev,build]"
ruff check .
pytest -q
```

## Single-Binary Build

The PoC uses PyInstaller for a one-file console executable:

```
python scripts/build_binary.py
python scripts/smoke_binary.py
```

The binary is written to `dist/pwned-check` on macOS/Linux and `dist/pwned-check.exe` on Windows.

Signing is intentionally deferred:
- macOS: codesign and notarization
- Windows: Authenticode signing
