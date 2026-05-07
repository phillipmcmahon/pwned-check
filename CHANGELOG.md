# Changelog

All notable project changes should be recorded here. Keep the format
lightweight and package-focused.

## Unreleased

## v1.0.3 - 2026-05-08

### Changed

- Hardened native PAM checker process launch handling so the post-fork child
  path exits directly if process-group setup fails.
- Serialized checker launches within a PAM process to prevent bounded stderr
  pipe inheritance between concurrent checker children.
- Enforced positive provider timeouts for direct provider construction and set
  the HTTP client timeout as a backstop.
- Split native PAM audit events for empty password tokens and PAM token
  retrieval errors.
- Extended the private signing material guard to detect binary GnuPG keyring
  filename patterns.

### Known Limitations

- Repository-generation and smoke-test Docker base images are not yet pinned by
  digest. Release builds validate package metadata, signatures, and live
  repository endpoints, but exact container image reproducibility is not yet a
  release gate.

## v1.0.1 - 2026-05-07

### Changed

- Fail-open PAM enforcement now allows provider-availability timeouts as well
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
- Configurable fail-open or fail-closed provider-availability policy through the
  package enable commands.
- Safe structured logging without plaintext passwords, full SHA-1 hashes, or
  SHA-1 suffixes.
- Checker CLI with documented stdin and exit-code contract.

### Known Limitations

- Repository-generation and smoke-test Docker base images are not yet pinned by
  digest. Release builds validate package metadata, signatures, and live
  repository endpoints, but exact container image reproducibility is not yet a
  release gate.
