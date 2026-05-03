# Package Repositories

This plan describes how native PAM package distribution moves from GitHub release assets to signed distro package repositories. The current release target is package files attached to GitHub Releases. Repository publication is the next production deployment track.

## Current Channel

GitHub Releases are the bootstrap distribution channel for native PAM packages:

| Distro family | Release asset | Install tool |
|---|---|---|
| Debian/Ubuntu | `pwned-check-native-pam_<version>_amd64.deb` | `apt install ./...deb` |
| Fedora/RHEL/Rocky | `pwned-check-native-pam-<version>-1.<dist>.x86_64.rpm` | `dnf install ./...rpm` |
| Arch Linux | `pwned-check-native-pam-<version>-1-x86_64.pkg.tar.zst` | `pacman -U ./...pkg.tar.zst` |
| Alpine Linux-PAM | `pwned-check-native-pam-<version>-r0.apk` | `apk add --allow-untrusted ./...apk` |

Release assets must include per-file SHA256 files, native aggregate checksums, and native package provenance. Package installation must place files only; PAM enablement stays explicit and starts in `dry_run` mode.

## Repository Targets

Repository publication should be added in this order:

| Stage | Repository | Signing | Publication gate |
|---|---|---|---|
| 1 | apt repository for Debian/Ubuntu | Signed `Release` metadata and package checksums | `.deb` package smoke on Ubuntu and Debian VMs |
| 2 | dnf/yum repository for Fedora/RHEL/Rocky | Signed RPMs and signed repository metadata | RPM package smoke plus Fedora SELinux assessment |
| 3 | Arch custom repository | Signed package and repository database | Arch package smoke |
| 4 | Alpine repository | Signed APK index and trusted public key docs | Alpine Linux-PAM package smoke |

Repository keys must be generated and stored outside the repository and outside persistent test VMs. Public keys can be checked in only after the key-management process is documented.

## Required Stories

Create these stories before implementation:

| Story | Exit criteria |
|---|---|
| Apt repository publication | Build signed apt repository metadata, publish the public key and source list instructions, install from the repository on Ubuntu and Debian VMs, enable/rollback the PAM profile, and remove the package cleanly |
| RPM repository publication | Sign RPMs, build signed dnf/yum metadata, install from the repository on Fedora, run authselect enable/rollback, and confirm SELinux remains clean |
| Arch repository publication | Build and sign the package database, install through `pacman -S`, run manual helper enable/rollback, and remove the package cleanly |
| Alpine repository publication | Build and sign the APK index, install through `apk add` using the documented public key, run manual helper enable/rollback on Linux-PAM, and remove the package cleanly |
| Repository key rotation and revocation | Document key location, rotation process, revocation notice path, and how operators update trusted keys |

## Acceptance Rules

- Repository packages must be byte-for-byte the same package outputs or rebuilt from the same release tag with matching provenance.
- Repository publication must not require GitHub credentials on distro test VMs.
- Every repository install test must include package removal and PAM rollback.
- Published instructions must include checksum or signature verification before enablement.
- A failed repository publication must not mutate an existing released package in place; publish a corrected patch release instead.
