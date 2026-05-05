# Package Repositories

This plan describes how native PAM package distribution moves from GitHub release assets to signed distro package repositories. The current release target is package files attached to GitHub Releases. Repository publication is the next production deployment track.

## Current Channel

GitHub Releases are the bootstrap distribution channel for native PAM packages:

| Distro family | Release asset | Install tool |
|---|---|---|
| Debian/Ubuntu | `pwned-check-native-pam_<version>_<arch>.deb` | `apt install ./...deb` |
| Fedora/RHEL/Rocky | `pwned-check-native-pam-<version>-1.<dist>.<arch>.rpm` | `dnf install ./...rpm` |
| Arch Linux | `pwned-check-native-pam-<version>-1-x86_64.pkg.tar.zst` | `pacman -U ./...pkg.tar.zst` |
| Alpine Linux-PAM | `pwned-check-native-pam-<version>-r0.apk` | `apk add --allow-untrusted ./...apk` |

Release assets must include per-file SHA256 files, native aggregate checksums, and native package provenance. Package installation must place files only; PAM enablement stays explicit and starts in `dry_run` mode.

Current release automation builds Debian/Ubuntu, Fedora/RHEL/Rocky, and Alpine
native PAM packages for `amd64`/`x86_64` and `arm64`/`aarch64`. Arch package
assets are `x86_64` only until an Arch Linux ARM builder image or persistent VM
is selected.

All native package families expose the same operator commands after installation:

| Command | Purpose |
|---|---|
| `pwned-check-pam-enable-dry-run` | Enable the native module in dry-run mode and record rollback state |
| `pwned-check-pam-enable-enforce` | Switch the enabled native module to enforcement after dry-run validation |
| `pwned-check-pam-disable` | Restore the recorded PAM or authselect rollback state |

Debian/Ubuntu and Fedora/RHEL packages install these commands under `/usr/sbin`; Arch packages install them under `/usr/bin`; Alpine packages install them under `/usr/sbin`. Operators should call the command name rather than hard-coding the path when possible.

## Repository Targets

Repository publication should be added in this order:

| Stage | Repository | Signing | Publication gate |
|---|---|---|---|
| 1 | apt repository for Debian/Ubuntu | Signed `Release` metadata and package checksums | `.deb` package smoke on Ubuntu and Debian VMs |
| 2 | dnf/yum repository for Fedora/RHEL/Rocky | Signed RPMs and signed repository metadata | RPM package smoke plus Fedora SELinux assessment |
| 3 | Arch custom repository | Signed package and repository database | Arch package smoke |
| 4 | Alpine repository | Signed APK index and trusted public key docs | Alpine Linux-PAM package smoke |

Repository keys must be generated and stored outside the repository and outside persistent test VMs. Public keys can be checked in only after the key-management process is documented.

## Signing Inputs

Repository publication needs a signing environment, not ad hoc signing on the test VMs. The release workstation or CI signing runner must provide:

| Input | Required for | Notes |
|---|---|---|
| OpenPGP release key | Apt `InRelease`/`Release.gpg`, detached checksum/provenance signatures, optional Arch package signatures | Private key must stay outside the repository and outside distro VMs |
| RPM signing key | RPM package signatures and optional `repomd.xml` signatures | Configure through the signing environment's RPM macro file, not committed repo config |
| Alpine RSA key | APK package/index signing | Public key is published for `/etc/apk/keys`; private key remains in the signing environment |
| Release provenance inputs | All repositories | Use `SOURCE_DATE_EPOCH` from the release tag timestamp and `make native-pam-release-provenance` after packages are staged |

Public keys may be published in the repository only after their fingerprints, rotation policy, revocation notice path, and operator update steps are documented.

## Publication Layout

The repository layout should be generated from the already validated release package set:

| Repository | Metadata tool | Expected public layout |
|---|---|---|
| Apt | `dpkg-scanpackages` or `aptly`/`reprepro` | `dists/<suite>/Release`, `InRelease`, `Release.gpg`, and `pool/main/p/pwned-check-native-pam/*.deb` |
| DNF/Yum | `createrepo_c` plus RPM signing | `repodata/repomd.xml`, optional `repomd.xml.asc`, and signed RPMs |
| Arch | `repo-add --sign` | `<repo>.db.tar.*`, `<repo>.files.tar.*`, signatures, and signed `pkg.tar.zst` packages |
| Alpine | `apk index` plus `abuild-sign`/`openssl` signing | `APKINDEX.tar.gz`, `APKINDEX.tar.gz.sig`, packages, and published public RSA key |

Repository metadata must be immutable for a published version. If metadata or a package is wrong after publication, publish a corrected patch release or clearly versioned repository metadata update; do not replace a package payload at the same version.

## Repository Smoke Tests

Each repository story must add an install test that uses only repository configuration and public keys on the target host:

| Repository | Required smoke |
|---|---|
| Apt | Add the public key and source list on Ubuntu and Debian VMs, `apt update`, install `pwned-check-native-pam`, run dry-run/enforce/disable, remove the package, and verify managed files are gone |
| DNF/Yum | Add the repo file on Fedora, install with `dnf`, run dry-run/enforce/disable through authselect, remove the package, and rerun SELinux assessment |
| Arch | Add the custom repository and public key in an Arch container until a VM exists, install with `pacman -S`, run dry-run/enforce/disable, remove the package, and verify managed files are gone |
| Alpine | Add the public key and repository URL on the Alpine VM, install with `apk add`, run dry-run/enforce/disable on a Linux-PAM service, remove the package, and verify managed files are gone |

The repository smoke must not require GitHub credentials or build tools on the distro host. It should consume only the published repository endpoint, public key material, and normal package manager commands.

## Required Stories

Create these stories before implementation:

| Story | Exit criteria |
|---|---|
| Apt repository publication | Build signed apt repository metadata, publish the public key and source list instructions, install from the repository on Ubuntu and Debian VMs, run dry-run/enforce/disable, and remove the package cleanly |
| RPM repository publication | Sign RPMs, build signed dnf/yum metadata, install from the repository on Fedora, run authselect dry-run/enforce/disable, and confirm SELinux remains clean |
| Arch repository publication | Build and sign the package database, install through `pacman -S`, run manual helper dry-run/enforce/disable, and remove the package cleanly |
| Alpine repository publication | Build and sign the APK index, install through `apk add` using the documented public key, run manual helper dry-run/enforce/disable on Linux-PAM, and remove the package cleanly |
| Repository key rotation and revocation | Document key location, rotation process, revocation notice path, and how operators update trusted keys |

## Acceptance Rules

- Repository packages must be byte-for-byte the same package outputs or rebuilt from the same release tag with matching provenance.
- Repository publication must not require GitHub credentials on distro test VMs.
- Every repository install test must include package removal and PAM rollback.
- Published instructions must include checksum or signature verification before enablement.
- A failed repository publication must not mutate an existing released package in place; publish a corrected patch release instead.
