# pwned-check Roadmap

This roadmap records the current product direction. The supported application
is a Linux package-repository deployment: a Go checker binary invoked by a Rust
Linux PAM module during password changes.

## Current Baseline

The Linux package path is the production baseline:

- signed apt, RPM, Arch, and Alpine repositories
- native PAM package for Debian/Ubuntu, Fedora/Rocky, Arch, and Alpine
  Linux-PAM
- dry-run, enforcement, rollback, and removal commands installed by each
  package
- live HIBP Pwned Passwords range API checks through the checker boundary
- mocked provider tests and release fuzzing so CI does not depend on the live
  provider
- persistent VM smoke coverage for supported package families and
  architectures

Current operator guidance is [Linux package install](linux-install.md).

## Linux Maintenance

Linux work should keep the package path simple and reliable:

- preserve the documented checker stdin and exit-code contract
- keep plaintext passwords out of argv, logs, files, and environment variables
- keep PAM behavior self-contained through `pam_get_authtok`
- keep package enablement explicit, starting with dry-run
- keep rollback and removal tested for every package family
- keep repository signatures, metadata, and endpoint monitoring healthy
- keep release evidence tied to the exact commit and GitHub Actions runs that
  validated it

## Targeted Hardening

Hardening work should be small and directly testable:

- tighten native PAM process isolation where it materially reduces risk
- keep parser fuzzing bounded and stable in CI
- keep release-package verification strict for package version, placement,
  permissions, dependencies, checksums, and repository visibility
- keep VM and Docker coverage split clearly between real-host acceptance and CI
  parity checks

## Platform Expansion

macOS and Windows remain future feasibility tracks. They should not be shipped
until their signing, platform security, package/update, and rollback models are
designed and validated to the same standard as the Linux package path.
