# Changelog

All notable project changes should be recorded here. Keep the format
lightweight and package-focused.

## Unreleased

## v1.0.1 - 2026-05-07

### Changed

- Fail-open PAM enforcement now allows provider availability timeouts as well
  as explicit provider failures. Local checker configuration, exec, and
  unexpected-exit failures still reject password changes.

## v1.0.0 - 2026-05-07

### Released

- First public Linux release of `pwned-check`.
- Native Linux PAM package for blocking known-breached passwords during
  password changes.
- Signed package repositories for Debian/Ubuntu, Fedora/RHEL/Rocky, Arch
  Linux, and Alpine Linux-PAM.
- Supported package architectures:
  - Debian/Ubuntu: `amd64`, `arm64`
  - Fedora/RHEL/Rocky: `x86_64`, `aarch64`
  - Arch Linux: `x86_64`
  - Alpine Linux-PAM: `x86_64`, `aarch64`
- Operator commands for dry-run, enforcement, rollback, and package removal.
- Configurable fail-open or fail-closed provider-outage behavior through the
  package enable commands.
- Safe structured logging without plaintext passwords, full SHA-1 hashes, or
  SHA-1 suffixes.
- Checker CLI with documented stdin and exit-code contract.

### Known Limitations

- Repository-generation and smoke-test Docker base images are not yet pinned by
  digest. Release builds validate package metadata, signatures, and live
  repository endpoints, but exact container image reproducibility is not yet a
  release gate.
