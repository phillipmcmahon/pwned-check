# Changelog

All notable project changes should be recorded here.

The format is intentionally lightweight while the project is pre-production.

## Unreleased

- Linux-first Go checker baseline.
- Project board and roadmap structure.
- Documentation skeleton for requirements, operations, security model, testing, and releases.
- Staticcheck pinned and added to local/CI validation.
- CLI hardening for config validation, provider timeouts, safe log events, and release version injection.
- Linux PAM PoC helper, example PAM config, and manual test/rollback documentation.
- Docker smoke matrix for Debian, Ubuntu, Alpine, Arch Linux, and Fedora minimal images.
- Linux release package workflow with tarballs, install script, build metadata, and SHA256 checksums.
- Docker PAM package smoke tests that install the Linux package, write `/etc/pam.d` config, and validate allow/reject combinations through `pam_exec.so expose_authtok`.
- Live HIBP provider policy documentation and mocked HIBP endpoint tests for fail-open/fail-closed behavior.
- Operational security docs for logging, rollout checks, troubleshooting, and parser fuzz coverage.
- CI and smoke coverage for bounded parser fuzzing, mocked HIBP provider checks, and fail-open/fail-closed outage paths.
- CI Linux artifact duplication removed by keeping Linux release packages as the canonical Linux build output.
