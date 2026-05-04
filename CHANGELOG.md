# Changelog

All notable project changes should be recorded here.

The format is intentionally lightweight while the project is pre-production.

## Unreleased

- No unreleased changes yet.

## v0.1.5 - 2026-05-04

- Local pre-push validation now runs native PAM package smoke tests against clean package installs on the persistent Ubuntu, Debian, Fedora, Rocky, and Alpine VMs.
- Rocky Linux package validation now uses the persistent Rocky VM instead of Docker.
- GitHub CI now runs Docker PAM package smoke coverage for both `linux/amd64` and `linux/arm64` across Debian, Ubuntu, Fedora, and Alpine images.
- Docker PAM smoke tooling now maps the requested platform to the matching Go architecture so arm64 package installs exercise arm64 binaries.
- Native PAM release documentation now records the remaining Arch arm64 coverage gap until an Arch Linux ARM builder image or VM is selected.

## v0.1.2 - 2026-05-03

- GitHub release workflow now builds and publishes native Linux PAM package assets at release creation time, which is required because published releases are immutable.
- Native PAM release assets now include Debian/Ubuntu `.deb`, Fedora/RPM `.rpm`, Arch package, Alpine APK, per-package checksums, build metadata, aggregate native checksums, and native package provenance.
- Native package provenance now consistently includes every `pwned-check-native-pam*` release file instead of partially including only some package metadata by filename shape.
- Alpine native package smoke can export package artifacts for release assembly, matching the existing Arch export path.

## v0.1.1 - 2026-05-03

- Native PAM module now falls back to Linux PAM's `pam_get_authtok` helper when `PAM_AUTHTOK` is not already populated, allowing Debian/Ubuntu deployments to enable `pam_pwned_check.so` without requiring `pam_pwquality` solely for token collection.
- Native checker runner now preflights path-qualified missing or non-executable checkers and maps them to deterministic exec failures before fork/exec.
- Alpine native PAM packaging now handles observed Linux-PAM module directory differences across the persistent Alpine VM and the pinned Alpine Docker image.
- Native PAM package smoke output now prints the selected PAM client, distro identity, and generated PAM service for easier failure triage.
- Release validation records exact `0.1.0-rc1` native package smoke results across Debian, Fedora, Arch, Alpine, and helper-package Docker paths.
- Local pre-push Docker validation now runs only targets without persistent VMs, while Debian, Ubuntu, Fedora, and Alpine release validation remains VM-first.

## v0.1.0 - 2026-05-02

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
- Native PAM module implementation for PAM argv parsing, `PAM_AUTHTOK` retrieval, checker invocation with hard timeout, dry-run mapping, safe user-facing messages, and persistent Ubuntu smoke coverage for clean, pwned, provider, timeout, config, dry-run, and invalid-argument cases.
- Native PAM Ubuntu smoke assertions for exact PAM conversation messages, checker `--stdin` argv, candidate-over-stdin delivery, fail-closed environment propagation, invalid-argument short-circuiting, and no candidate leakage to PAM output.
- Persistent Debian VM validation for native PAM unit/build/dependency/symbol gates, host harness, Debian/Ubuntu package-layout smoke, and native `.deb` package smoke.
