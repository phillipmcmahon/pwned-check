# Package Repositories

This document describes the signed distro package repositories for native PAM
package distribution. GitHub Release assets remain the immutable bootstrap and
recovery channel; repository-backed package manager installs are the normal
production-style operator path.

Repository-backed releases must satisfy the [Production release gate](production-release-gate.md) before they are described as production-ready.

## Implementation Status

Epic 8 has repository-generation, production GitHub Pages hosting, and
repo-only smoke coverage for each target family. The production hosting and key
model is tracked in
[#39](https://github.com/phillipmcmahon/pwned-check/issues/39):

- host the first production repositories on GitHub Pages under
  `https://phillipmcmahon.github.io/pwned-check/`
- use one maintainer-owned OpenPGP production key for apt, RPM, and Arch
- use one maintainer-owned Alpine RSA production key for the APK repository
- keep private keys outside the repository, GitHub Pages branch, and distro VMs

Repository metadata is generated from immutable GitHub Release assets and signed
with the production keys. GitHub Release assets remain the immutable release
artifact source and bootstrap fallback.

| Family | Repository generation | Published repo smoke | Current limitation |
|---|---|---|---|
| Apt | `scripts/build-native-pam-apt-repository.sh` | Ubuntu and Debian VMs with `scripts/native-pam-apt-repo-smoke.sh --repo-url https://phillipmcmahon.github.io/pwned-check/apt` | None for published `amd64`; `arm64` metadata is published and intentionally deferred until an explicitly provisioned arm64 Debian or Ubuntu VM is available |
| DNF/Yum | `scripts/build-native-pam-rpm-repository.sh` | Fedora and Rocky VMs with `scripts/native-pam-rpm-repo-smoke.sh --repo-url https://phillipmcmahon.github.io/pwned-check/rpm` | None for published `x86_64`; `aarch64` metadata is published and intentionally deferred until an explicitly provisioned aarch64 Fedora or Rocky VM is available |
| Arch | `scripts/build-native-pam-arch-repository.sh` | `codex-vm-arch` with `scripts/native-pam-arch-repo-smoke.sh` | `x86_64` only; Arch Linux ARM support is deferred until a persistent Arch Linux ARM VM or trusted builder path is selected |
| Alpine | `scripts/build-native-pam-alpine-repository.sh` | `aarch64` Docker smoke against `https://phillipmcmahon.github.io/pwned-check/alpine` | The immutable `v0.1.6` GitHub Release contains an `aarch64` APK only; the persistent Alpine VM is `x86_64`, so x86_64 publication is deferred until a release contains a signed x86_64 APK and repository index |

GitHub Pages endpoints:

| Family | Endpoint |
|---|---|
| Apt | `https://phillipmcmahon.github.io/pwned-check/apt` |
| DNF/Yum | `https://phillipmcmahon.github.io/pwned-check/rpm` |
| Arch | `https://phillipmcmahon.github.io/pwned-check/arch` |
| Alpine | `https://phillipmcmahon.github.io/pwned-check/alpine` |

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

Published repository architecture status is deliberately narrower than package
build support when a matching persistent VM does not exist:

| Family | Published architectures | Real-host repository smoke | Deferred repository smoke |
|---|---|---|---|
| Apt | `amd64`, `arm64` | `amd64` on Ubuntu and Debian VMs | `arm64` until an arm64 Debian or Ubuntu VM is provided |
| DNF/Yum | `x86_64`, `aarch64` | `x86_64` on Fedora and Rocky VMs | `aarch64` until an aarch64 Fedora or Rocky VM is provided |
| Arch | `x86_64` | `x86_64` on the Arch VM | Arch Linux ARM until the project selects a builder or VM |
| Alpine | `aarch64` for `v0.1.6` | None on the persistent Alpine VM because it is `x86_64` | `x86_64` until a release includes a signed x86_64 APK/index; native aarch64 until an aarch64 Alpine VM is provided |

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

Repository keys must be generated and stored outside the repository and outside persistent test VMs. Public keys can be checked in only after the key-management process is documented in the [Production release gate](production-release-gate.md) and the key-rotation story.

## Signing Inputs

Repository publication needs a signing environment, not ad hoc signing on the test VMs. The release workstation or CI signing runner must provide:

| Input | Required for | Notes |
|---|---|---|
| OpenPGP production key | Apt `InRelease`/`Release.gpg`, RPM package signatures and optional `repomd.xml` signatures, Arch package/database signatures, detached checksum/provenance signatures | One maintainer-owned private key for apt/RPM/Arch; private key must stay outside the repository, GitHub Pages branch, and distro VMs |
| Alpine RSA key | APK package/index signing | Public key is published for `/etc/apk/keys`; private key remains in the signing environment |
| Release provenance inputs | All repositories | Use `SOURCE_DATE_EPOCH` from the release tag timestamp and `make native-pam-release-provenance` after packages are staged |

Public keys may be published in the repository only after their fingerprints, rotation policy, revocation notice path, and operator update steps are documented.

The signing responsibilities and private-key prohibitions are canonical in the [Production release gate](production-release-gate.md#signing-model).

## Key Rotation And Revocation

Repository key lifecycle is a release-maintainer responsibility. Private keys
belong only in the release signing environment or managed signing runner. They
must not be committed, copied to persistent distro VMs, embedded in smoke
fixtures, or stored beside published repository payloads.

Publish a small key record with every repository-backed production release:

| Field | Required content |
|---|---|
| Key purpose | Apt/release OpenPGP, RPM signing, Arch OpenPGP, or Alpine RSA |
| Public fingerprint | Full fingerprint for OpenPGP/RPM/Arch keys, or SHA256 fingerprint of the Alpine RSA public key |
| Storage owner | Human maintainer or signing-runner owner responsible for the private key |
| Created and expires | Creation date and expiry date, or `no expiry` with rationale |
| Rotation due | Planned replacement date, normally before expiry and before maintainer ownership changes |
| Revocation notice path | Release notes, repository notice file, GitHub security advisory when appropriate, and operator communication channel |

Planned rotation:

Rotate repository signing keys annually by default, and immediately on any
suspicion of key exposure, maintainer handover risk, or signing-environment
compromise. Set the next planned rotation date when each key is created and
record it in release notes or the operator key inventory.

Rehearse the planned rotation process annually even when the active keys are
not being replaced. The rehearsal should use non-production test keys and
confirm key export, metadata signing, operator trust-bootstrap instructions,
revocation-notice drafting, and rollback to the current production trust path.
Run the rehearsal alongside the annual rotation planning window when possible.

1. Generate the replacement key in the release signing environment.
2. Publish the replacement public key and fingerprint before using it.
3. Sign the next repository metadata with the replacement key.
4. Update the scheduled repository endpoint monitor constants in
   `scripts/native-pam-repo-endpoint-check.sh`: `OPENPGP_FPR` for apt, RPM, and
   Arch rotations, and `ALPINE_KEY_SHA256` for Alpine RSA key rotations.
5. Keep the previous public key available until all supported repository
   metadata signed by it has aged out.
6. Do not replace already published package payloads at the same version. If a
   signing mistake affects a shipped package, publish a corrected patch release.

Emergency revocation or compromised key:

1. Stop repository publication from the affected signing environment.
2. Publish a revocation notice that includes the affected fingerprint, first
   known bad version or timestamp, operator action, and replacement key
   fingerprint when available.
3. Generate a replacement key in a clean signing environment.
4. Republish repository metadata signed by the replacement key without silently
   replacing existing package payloads. Use a new package version if payloads
   must change.
5. Instruct operators to remove the affected trusted key, install the
   replacement public key, refresh repository metadata, and reinstall or upgrade
   to the corrected version.

Expired key recovery is the same as planned rotation except the old key cannot
be relied on for new metadata. Publish the replacement public key fingerprint
through the release notes and the repository trust-bootstrap page before asking
operators to refresh package metadata.

Operator public-key update commands:

| Family | Update public key |
|---|---|
| Apt | Install the replacement armored key under `/etc/apt/keyrings/pwned-check.asc`, update the `signed-by=` source-list entry if the filename changes, then run `sudo apt update`. |
| DNF/Yum | Install the replacement public key file, update `gpgkey=` in `/etc/yum.repos.d/pwned-check-native-pam.repo` if the URL changes, then run `sudo dnf clean metadata && sudo dnf makecache`. |
| Arch | `sudo pacman-key --delete <old-fingerprint>`, `sudo pacman-key --add <new-key.asc>`, `sudo pacman-key --lsign-key <new-fingerprint>`, then `sudo pacman -Sy`. |
| Alpine | Replace `/etc/apk/keys/pwned-check-native-pam.rsa.pub` with the new public RSA key, remove the old key file if the name changed, then run `sudo apk update`. |

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
| Arch | Add the custom repository and public key on `codex-vm-arch`, install with `pacman -S`, run dry-run/enforce/disable, remove the package, and verify managed files are gone |
| Alpine | Add the public key and repository URL on the Alpine VM, install with `apk add`, run dry-run/enforce/disable on a Linux-PAM service, remove the package, and verify managed files are gone |

The repository smoke must not require GitHub credentials or build tools on the distro host. It should consume only the published repository endpoint, public key material, and normal package manager commands.

The required repository-only smoke gate is defined in [Production release gate](production-release-gate.md#repository-only-smoke-gate).
For repository-backed release promotion, run the published endpoint wrapper:

```bash
make native-pam-live-repo-smokes
```

The wrapper runs apt, RPM, and Arch live endpoint smokes on persistent VMs where
architecture coverage exists. Alpine is recorded as deferred unless
`PWNED_CHECK_ALPINE_REPO_SMOKE_HOSTS` points at a matching persistent Alpine VM.

For continuous availability monitoring, the scheduled `Repository Endpoints`
GitHub Actions workflow runs:

```bash
make native-pam-repo-endpoint-check
```

That check verifies public-key availability, signed apt/RPM/Arch metadata,
Alpine signed-index presence, and package entries from the published endpoint
without installing packages or mutating PAM state.

## Apt Repository

The apt repository path is the first Epic 8 repository implementation target.
Generate metadata from already validated `.deb` artifacts and sign the suite
metadata with a release signing key that lives outside the repository and
outside the distro test VMs:

```bash
PWNED_CHECK_APT_SIGNING_KEY="<key fingerprint>" \
  ./scripts/build-native-pam-apt-repository.sh \
    --input-dir dist/release \
    --output-dir dist/apt-repository \
    --suite stable \
    --component main \
    --public-key-output dist/apt-repository/pwned-check-archive-key.asc
```

The generated repository contains:

| Path | Purpose |
|---|---|
| `pool/main/p/pwned-check-native-pam/*.deb` | Validated package payloads |
| `dists/<suite>/Release` | Unsigned suite metadata |
| `dists/<suite>/InRelease` | Inline signed suite metadata used by apt |
| `dists/<suite>/Release.gpg` | Detached signature for suite metadata |
| `dists/<suite>/<component>/binary-<arch>/Packages*` | Package index per architecture |

Operator trust bootstrap should install the public key into `/etc/apt/keyrings`
and scope trust to the pwned-check source list:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://phillipmcmahon.github.io/pwned-check/pwned-check-openpgp-production.asc |
  sudo tee /etc/apt/keyrings/pwned-check-native-pam.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/pwned-check-native-pam.asc] https://phillipmcmahon.github.io/pwned-check/apt stable main" |
  sudo tee /etc/apt/sources.list.d/pwned-check-native-pam.list >/dev/null
sudo apt update
sudo apt install pwned-check-native-pam
```

Before enabling the repository, verify the OpenPGP fingerprint is
`BDF6 F4DD 343E 9F10 EA9D  B510 FDDA 2848 A95A D641`.
Package installation still only places files. Enablement remains explicit:

```bash
sudo pwned-check-pam-enable-dry-run
sudo pwned-check-pam-enable-enforce
sudo pwned-check-pam-disable
```

Repo-only smoke copies the prepared repository and public key to a target VM,
configures apt from those files, installs the package through apt, exercises
dry-run/enforce/disable, purges the package, and verifies managed files are
removed:

```bash
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-ubuntu
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-debian
```

The VM does not need GitHub credentials, repository source code, Rust, Go, or C
build tooling for this repo-only smoke.

## RPM Repository

The RPM-family repository path signs package headers and repository metadata.
Generate metadata from already validated `.rpm` artifacts and sign with a key
held in the release signing environment:

```bash
PWNED_CHECK_RPM_SIGNING_KEY="<key fingerprint>" \
  ./scripts/build-native-pam-rpm-repository.sh \
    --input-dir dist/release \
    --output-dir dist/rpm-repository \
    --public-key-output dist/rpm-repository/RPM-GPG-KEY-pwned-check-native-pam.asc
```

The generated repository contains signed RPMs, `repodata/repomd.xml`, and
`repodata/repomd.xml.asc`. Operator repository configuration must require both
package and metadata signature checks:

```ini
[pwned-check-native-pam]
name=pwned-check native PAM repository
baseurl=https://phillipmcmahon.github.io/pwned-check/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
```

Install the public key and package through normal dnf/yum operations:

```bash
sudo install -d -m 0755 /etc/pki/rpm-gpg
curl -fsSL https://phillipmcmahon.github.io/pwned-check/rpm/RPM-GPG-KEY-pwned-check-native-pam.asc |
  sudo tee /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam >/dev/null
sudo rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
sudo dnf install pwned-check-native-pam
```

Before enabling the repository, verify the OpenPGP fingerprint is
`BDF6 F4DD 343E 9F10 EA9D  B510 FDDA 2848 A95A D641`.
Package installation still only places files. Enablement remains explicit:

```bash
sudo pwned-check-pam-enable-dry-run
sudo pwned-check-pam-enable-enforce
sudo pwned-check-pam-disable
```

Repo-only smoke copies the prepared repository and public key to a target VM,
configures dnf/yum with `gpgcheck=1` and `repo_gpgcheck=1`, installs from the
repository, exercises dry-run/enforce/disable, removes the package, and verifies
managed files are gone:

```bash
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-fedora
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-rocky
```

The VM does not need GitHub credentials, repository source code, Rust, Go, C
build tooling, `rpmbuild`, or `createrepo_c` for this repo-only smoke.

## Arch Repository

The Arch repository path signs both the package files and the pacman repository
database. Generate metadata from already validated `.pkg.tar.zst` artifacts and
keep the private key in the release signing environment:

```bash
PWNED_CHECK_ARCH_SIGNING_KEY="release-key-fingerprint" \
  ./scripts/build-native-pam-arch-repository.sh \
    --input-dir dist/release \
    --output-dir dist/arch-repository \
    --public-key-output dist/arch-repository/pwned-check-native-pam.asc
```

The generated repository is split by pacman architecture, for example
`x86_64/pwned-check.db` and `x86_64/pwned-check.files`. Package signatures
remain next to the packages as `.sig` files, and the repository database is
signed by `repo-add --sign`.

Operator trust bootstrap should import the public key, locally sign it in the
pacman keyring, and add the custom repository:

```bash
curl -fsSL https://phillipmcmahon.github.io/pwned-check/pwned-check-openpgp-production.asc \
  -o /tmp/pwned-check-native-pam.asc
sudo pacman-key --add /tmp/pwned-check-native-pam.asc
sudo pacman-key --lsign-key BDF6F4DD343E9F10EA9DB510FDDA2848A95AD641
sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[pwned-check]
SigLevel = Required DatabaseRequired
Server = https://phillipmcmahon.github.io/pwned-check/arch/$arch
EOF
sudo pacman -Sy pwned-check-native-pam
```

Before locally signing the key, verify the OpenPGP fingerprint is
`BDF6 F4DD 343E 9F10 EA9D  B510 FDDA 2848 A95A D641`. Do not use
`SigLevel = Never` or `pacman -U` for repository-backed production validation.

Package installation still only places files. Enablement remains explicit:

```bash
sudo pwned-check-pam-enable-dry-run
sudo pwned-check-pam-enable-enforce
sudo pwned-check-pam-disable
```

Repo-only smoke copies the prepared repository and public key to the Arch VM,
configures pacman trust, installs from the repository with `pacman -S`,
exercises dry-run/enforce/disable on a disposable Linux-PAM service, removes the
package, and verifies managed files are gone:

```bash
./scripts/native-pam-arch-repo-smoke.sh --host codex-vm-arch
```

The VM does not need GitHub credentials, repository source code, Rust, Go, C
build tooling, `makepkg`, or `repo-add` for this repo-only smoke.

Arch repository smoke currently covers `x86_64` on `codex-vm-arch`. Arch Linux
ARM coverage is deferred until a maintained Arch Linux ARM builder image or
persistent VM is selected.

Arch Linux ARM is a deliberate deferral for the v0.2 readiness path. The
project will not publish Arch Linux ARM repository metadata from an unvetted
community builder image. Support can be reopened when a persistent Arch Linux
ARM VM is explicitly provided, when a trusted and pinned builder image is
selected, or when the project records a source-only Arch Linux ARM position
instead of binary package support.

## Alpine Repository

The Alpine repository path signs `APKINDEX.tar.gz` with an RSA key. Generate
metadata from already validated `.apk` artifacts and keep the private key in the
release signing environment:

```bash
PWNED_CHECK_ALPINE_SIGNING_KEY="/secure/path/pwned-check-native-pam.rsa" \
  ./scripts/build-native-pam-alpine-repository.sh \
    --input-dir dist/release \
    --output-dir dist/alpine-repository \
    --public-key-output dist/alpine-repository/pwned-check-native-pam.rsa.pub
```

The generated repository is split by APK architecture, for example
`x86_64/APKINDEX.tar.gz` and `aarch64/APKINDEX.tar.gz`. Operator trust
bootstrap should install the public RSA key under `/etc/apk/keys` and add the
published repository root to `/etc/apk/repositories`:

```bash
curl -fsSL https://phillipmcmahon.github.io/pwned-check/alpine/pwned-check-alpine-production.rsa.pub |
  sudo tee /etc/apk/keys/pwned-check-native-pam.rsa.pub >/dev/null
echo "https://phillipmcmahon.github.io/pwned-check/alpine" |
  sudo tee -a /etc/apk/repositories >/dev/null
sudo apk update
sudo apk add pwned-check-native-pam
```

Before enabling the repository, verify the Alpine RSA public key SHA256
fingerprint is
`8CC2BD76F364D3734C8A265B152FCEFFA6F3B90FC2857DB92D40BED4808F214F`. Do not
use `--allow-untrusted` for repository-backed production validation. Alpine
deployments require Linux-PAM; BusyBox-only password tooling is outside the
native PAM package scope.

Package installation still only places files. Enablement remains explicit:

```bash
sudo pwned-check-pam-enable-dry-run
sudo pwned-check-pam-enable-enforce
sudo pwned-check-pam-disable
```

Repo-only smoke copies the prepared repository and public key to the Alpine VM,
configures apk trust, installs from the repository without `--allow-untrusted`,
exercises dry-run/enforce/disable on a disposable Linux-PAM service, removes the
package, and verifies managed files are gone:

```bash
./scripts/native-pam-alpine-repo-smoke.sh --host codex-vm-alpine
```

The VM does not need GitHub credentials, repository source code, Rust, Go, C
build tooling, `abuild`, or `apk index` for this repo-only smoke.

### Alpine x86_64 Status

The persistent Alpine VM is `x86_64`, but the first published Alpine repository
from the immutable `v0.1.6` release assets contains only the `aarch64` APK. The
x86_64 package path itself is not rejected: the VM-backed Alpine package smoke
continues to validate package install, helper enablement, rollback, removal,
and managed-file cleanup from locally built artifacts. The publication gap is
that the immutable release asset set did not include a signed x86_64 APK and
matching `x86_64/APKINDEX.tar.gz`.

x86_64 Alpine repository publication is intentionally deferred until a future
release includes a signed x86_64 APK in the immutable asset set and the
published repository index. At that point, `scripts/native-pam-alpine-repo-smoke.sh
--host codex-vm-alpine --repo-url https://phillipmcmahon.github.io/pwned-check/alpine`
becomes a required live endpoint gate. Until then, the Alpine live endpoint is
validated through the documented aarch64 Docker path and recorded as a
real-host coverage gap in release notes.

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
