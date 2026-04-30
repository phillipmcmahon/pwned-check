# pwned-check

Cross-platform CLI that checks a password against the [Have I Been Pwned](https://haveibeenpwned.com/Passwords) Pwned Passwords range API using k-anonymity (only the first 5 chars of the SHA-1 hash are sent).

## Features
- Any-hit rejection policy
- Fail-open with warning (configurable fail-closed)
- Provider abstraction (HIBP online now; local/offline later)
- Logs only the 5-char prefix + outcome

## Usage
```
echo -n 'hunter2' | pwned-check --stdin
```

Exit codes: 0 clean, 1 pwned, 2 config/usage, 3 network error (fail-closed).
