# Linux PAM PoC

This document captures the first Linux password-change integration shape.

## Approach Decision

Use `pam_exec.so expose_authtok` plus a small `pwned-check-pam-helper` executable for the first PoC.

Why this shape:

- avoids native PAM module code while proving real process integration
- keeps breach-checking logic in the Go checker binary
- avoids passing the candidate password in argv
- gives us a helper-owned hard timeout around the checker process
- can be replaced by a native PAM module later without changing the checker contract

The `pam_exec` manual documents that `expose_authtok` lets the called command read the password from stdin during authentication and password change. See [pam_exec(8)](https://man7.org/linux/man-pages/man8/pam_exec.8.html).

## Components

```text
PAM password stack
  -> pam_exec.so expose_authtok
  -> pwned-check-pam-helper --checker /usr/local/bin/pwned-check --timeout 3s
  -> pwned-check --stdin
  -> live HIBP range API
```

## Helper Contract

`pwned-check-pam-helper`:

- reads the candidate password from stdin
- invokes `pwned-check --stdin`
- enforces a hard timeout around the checker process
- maps checker outcomes to PAM-compatible process exit codes
- never logs the plaintext password

Exit codes:

- `0`: allow password change
- `1`: reject password change
- `2`: helper usage/configuration error

Checker exit-code mapping:

| Checker exit | Meaning | Helper exit |
|---|---|---|
| `0` | clean, or provider failure when checker fail-open is configured | `0` |
| `1` | pwned password | `1` |
| `2` | checker config/usage error | `1` |
| `3` | checker provider/network error in fail-closed mode | `1` |
| timeout | checker exceeded helper timeout | `1` |

## Example PAM Config

Example file: [`examples/pam.d/common-password-pwned-check`](../examples/pam.d/common-password-pwned-check)

Debian/Ubuntu-style placement:

```text
password requisite pam_exec.so expose_authtok quiet /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check --timeout 3s
```

Place the line before `pam_unix.so` in `/etc/pam.d/common-password` so rejected passwords fail before the local password is changed.

## Manual Test Plan

Use a disposable VM. Keep an existing root shell open while testing PAM changes.

1. Build and install both binaries:

   ```bash
   make build
   sudo install -m 0755 dist/pwned-check /usr/local/bin/pwned-check
   sudo install -m 0755 dist/pwned-check-pam-helper /usr/local/bin/pwned-check-pam-helper
   ```

2. Smoke test the helper without PAM:

   ```bash
   printf 'password\n' | /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check --timeout 3s
   echo $?
   ```

   Expected result: exit code `1`.

3. Back up PAM config:

   ```bash
   sudo cp /etc/pam.d/common-password /etc/pam.d/common-password.pwned-check.bak
   ```

4. Add the example `pam_exec.so` line before `pam_unix.so`.

5. Try changing a test user's password to `password`:

   ```bash
   sudo passwd <test-user>
   ```

   Expected result: password change is rejected.

6. Try changing the same test user's password to a strong random value.

   Expected result: password change is allowed when the checker returns clean.

## Rollback

Restore the saved PAM file:

```bash
sudo cp /etc/pam.d/common-password.pwned-check.bak /etc/pam.d/common-password
```

Then test that `passwd` reaches the normal password-change flow again.

If live HIBP access is unavailable and the checker is configured fail-closed, rollback can also be achieved by changing the checker configuration back to fail-open while leaving the PAM line in place, but restoring the PAM file is the safest emergency rollback.

## Current Limitations

- This is a PoC integration path, not the final native PAM module.
- Distro PAM stacks vary; test on the exact target distro before rollout.
- The example is written for Debian/Ubuntu-style `common-password`.
- Production deployments use the live HIBP range API and must choose fail-open or fail-closed behavior before rollout.
