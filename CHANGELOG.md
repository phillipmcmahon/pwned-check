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
- Parser fuzzing split into 5s CI/pre-push smoke, 60s release validation, and 5m scheduled nightly runs.
- CI distributable artifacts limited to Linux `amd64` and `arm64` until macOS and Windows signing tracks are ready.
- Coverage gate added with 85% minimum coverage for internal product logic packages.
- Operational hardening for bounded checker input, public HIBP HTTPS validation, single-context provider timeouts, and bounded PAM checker stderr diagnostics.
- Documentation updates for Ubuntu PAM deployment, rollback, helper exit mapping, HIBP request volume, threat model details, versioning, and log examples.
- Staticcheck split into a standalone CI job ready for required branch protection, with release provenance attestation over published checksums.
- PAM helper `--max-bytes` option and Prometheus-style counter examples for operational log pipelines.
- Native PAM module Rust skeleton with safe-string fixtures, argument parsing tests, PAM constant tests, checker outcome mapping tests, exported PAM service stubs, Linux shared-library dependency allowlist CI, and exported-symbol CI.
- Persistent Ubuntu native PAM smoke container for building, installing, loading, and exercising `pam_pwned_check.so` through `pam_chauthtok` during development.
