# Package Repositories

This maintainer reference covers signed package repositories for the native
Linux PAM package. Operators should start with [Linux install](linux-install.md).

Repository-backed releases must satisfy the production release gate in
[Release playbook](release-playbook.md#release-gate).
Repository availability and response objectives are defined in the
[production baseline SLO](roadmap.md#production-baseline-slo).

## Status

Repositories are published on GitHub Pages:

| Family | Endpoint | Architectures | Local repository smoke |
|---|---|---|---|
| Apt | `https://phillipmcmahon.github.io/pwned-check/apt` | `amd64`, `arm64` | Ubuntu and Debian VMs |
| DNF/Yum | `https://phillipmcmahon.github.io/pwned-check/rpm` | `x86_64`, `aarch64` | Fedora and Rocky VMs |
| Arch | `https://phillipmcmahon.github.io/pwned-check/arch` | `x86_64` | Arch VM |
| Alpine | `https://phillipmcmahon.github.io/pwned-check/alpine` | `x86_64`, `aarch64` | Alpine VMs |

Arch Linux ARM is not targeted. Alpine support is Linux-PAM only.

All package families install:

- `pwned-check`
- `pam_pwned_check.so`
- `pwned-check-pam-enable-dry-run`
- `pwned-check-pam-enable-enforce`
- `pwned-check-pam-disable`
- package documentation under `/usr/share/doc/pwned-check/`

Debian/Ubuntu and Fedora/Rocky install wrapper commands under `/usr/sbin`.
Arch installs them under `/usr/bin`. Alpine installs them under `/usr/sbin`.
The enable commands accept `--fail-open` and `--fail-closed`; `--fail-open` is
the default.

## Signing Model

Use one maintainer-owned OpenPGP production key for apt, RPM, Arch, detached
checksums, and provenance signatures. Use one maintainer-owned Alpine RSA
production key for APK repository trust.

Private keys must remain outside:

- the git repository
- GitHub Pages
- persistent distro VMs
- smoke fixtures
- package repositories

Public keys may be published only after fingerprints, owner, storage
expectations, rotation due date, and revocation path are recorded.

## Key Rotation

Rotate repository signing keys annually by default, and immediately on suspected
exposure, maintainer handover risk, or signing-environment compromise. Rehearse
rotation annually with non-production test keys.

For every production key, record:

| Field | Required content |
|---|---|
| Purpose | Apt/RPM/Arch OpenPGP or Alpine RSA |
| Fingerprint | Full OpenPGP fingerprint or Alpine public-key SHA256 |
| Owner | Human maintainer or signing-runner owner |
| Created/expires | Creation and expiry dates, or `no expiry` with rationale |
| Rotation due | Planned replacement date |
| Revocation path | Release notes, repository notice file, GitHub advisory when appropriate |

Planned rotation:

1. Generate the replacement key in the release signing environment.
2. Publish the replacement public key and fingerprint before using it.
3. Sign the next repository metadata with the replacement key.
4. Update `OPENPGP_FPR` or `ALPINE_KEY_SHA256` in
   `scripts/native-pam-repo-endpoint-check.sh`.
5. Keep the previous public key available until metadata signed by it has aged out.
6. Never replace package payloads at an existing version. Publish a patch
   release if payloads must change.

Compromised or expired key recovery:

1. Stop publication from the affected signing environment.
2. Publish a revocation notice with the affected fingerprint and operator action.
3. Generate a replacement key in a clean signing environment.
4. Republish metadata signed by the replacement key.
5. Instruct operators to remove the old trusted key, install the replacement,
   refresh metadata, and upgrade or reinstall as needed.

Operator key updates:

| Family | Update |
|---|---|
| Apt | Replace `/etc/apt/keyrings/pwned-check.asc`, update `signed-by=` if the filename changes, then run `sudo apt update`. |
| DNF/Yum | Replace the public key file, update `gpgkey=` if the URL changes, then run `sudo dnf clean metadata && sudo dnf makecache`. |
| Arch | `sudo pacman-key --delete <old>`, `sudo pacman-key --add <new-key.asc>`, `sudo pacman-key --lsign-key <new>`, then `sudo pacman -Sy`. |
| Alpine | Replace `/etc/apk/keys/pwned-check-alpine-production.rsa.pub`, remove any old key file if renamed, then run `sudo apk update`. |

## Publication Layout

Generate repository metadata from the already validated release package set:

| Family | Builder | Public layout |
|---|---|---|
| Apt | `scripts/build-native-pam-apt-repository.sh` | `dists/<suite>/Release`, `InRelease`, `Release.gpg`, `pool/main/p/pwned-check-native-pam/*.deb` |
| DNF/Yum | `scripts/build-native-pam-rpm-repository.sh` | `repodata/repomd.xml`, optional `repomd.xml.asc`, signed RPMs |
| Arch | `scripts/build-native-pam-arch-repository.sh` | signed `<repo>.db.tar.*`, `<repo>.files.tar.*`, signed `pkg.tar.zst` packages |
| Alpine | `scripts/build-native-pam-alpine-repository.sh` | signed `APKINDEX.tar.gz`, packages, public RSA key |

Metadata and package payloads are immutable for a published version. Publish a
new patch version for payload corrections.

## Repository Generation On macOS

Generate repositories from immutable GitHub Release assets on the maintainer Mac
with Docker. Do not run repository generation on distro VMs.

Required local inputs:

- Docker Desktop with the staging directory shareable by Docker
- authenticated `gh` CLI when downloading release assets
- release package assets under `dist/release`, or a release tag to download
- signing material under `~/.pwned-check/signing/keys`
- the OpenPGP secret key available in the local macOS GPG keyring

The stable entrypoint is:

```bash
./scripts/build-native-pam-repositories-docker.sh \
  --version vX.Y.Z \
  --download-release-assets
```

The script stages inputs under `~/pwned-check-repository-build` by default
because Docker Desktop can mount that location reliably even when the checkout
lives under a restricted path such as `Documents`. It mounts the signing-key
directory read-only, exports a transient OpenPGP secret key from the local GPG
keyring into the staging directory, imports it inside each repository-tool
container, then removes the staged secret before exit.

Use a local, disposable staging path such as
`$HOME/pwned-check-repository-build`. The builder writes and verifies a
`.pwned-check-stage` marker before recreating that directory so an accidental
`--stage-dir` value cannot remove an unrelated path. On macOS, the staged key
directory also gets a `.metadata_never_index` marker to keep Spotlight from
indexing the temporary OpenPGP secret export.

The staged OpenPGP secret is removed on normal exit, `INT`, and `TERM`. A hard
reboot or `SIGKILL` cannot run shell cleanup traps, so avoid placing
`--stage-dir` under synced, backed-up, or shared folders. If a repository build
is forcibly killed, remove the staging directory before the next release run.

Generated outputs:

| Path | Purpose |
|---|---|
| `dist/apt-repository` | Apt repository output |
| `dist/rpm-repository` | RPM repository output |
| `dist/arch-repository` | Arch repository output |
| `dist/alpine-repository` | Alpine repository output |
| `dist/package-repositories` | Publishable GitHub Pages tree containing `apt/`, `rpm/`, `arch/`, `alpine/`, and public keys |

Use `dist/package-repositories` as the source for the `gh-pages` publication
copy. It already includes the public OpenPGP key at the repository root and the
family-specific compatibility aliases expected by the single operator guide,
[Linux install](linux-install.md).

Alpine index generation may warn about missing dependency providers because the
project repository contains only `pwned-check-native-pam`; the normal Alpine
base/community repositories provide `linux-pam` and shared-library packages
during real installs. The live Alpine repo smoke is the acceptance check.

Useful overrides:

```bash
PWNED_CHECK_REPOSITORY_DOCKER_STAGE="$HOME/pwned-check-repository-build" \
PWNED_CHECK_SIGNING_KEY_DIR="$HOME/.pwned-check/signing/keys" \
PWNED_CHECK_REPOSITORY_DOCKER_PLATFORM=linux/amd64 \
  ./scripts/build-native-pam-repositories-docker.sh --input-dir dist/release
```

If the OpenPGP secret key is not available in the local GPG keyring, export it
to a protected file outside the repo and pass it with:

```bash
PWNED_CHECK_OPENPGP_SECRET_KEY_FILE=/path/to/openpgp-secret.asc \
  ./scripts/build-native-pam-repositories-docker.sh --input-dir dist/release
```

## Repository Smoke

Repository smokes must use only public repository configuration, public keys,
and normal package-manager commands. Target hosts must not require GitHub
credentials, build tools, a local checkout, Cargo, Go, or private signing keys.

Run the full live endpoint wrapper:

```bash
make native-pam-live-repo-smokes
```

Run the non-mutating endpoint monitor:

```bash
make native-pam-repo-endpoint-check
```

Family-specific smokes:

```bash
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-ubuntu --repo-url https://phillipmcmahon.github.io/pwned-check/apt
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-fedora --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
./scripts/native-pam-arch-repo-smoke.sh --host codex-vm-arch --repo-url https://phillipmcmahon.github.io/pwned-check/arch
./scripts/native-pam-alpine-repo-smoke.sh --host codex-vm-alpine --repo-url https://phillipmcmahon.github.io/pwned-check/alpine
```

Each smoke must cover install, dry-run enablement, enforcement, disable, package
removal, and managed-file cleanup. RPM-family smokes must also keep SELinux
clean or record an explicit tracked exception.

Operator-facing repository setup commands live only in
[Linux install](linux-install.md). Keep this maintainer reference focused on
repository generation, signing, publication, and smoke validation so operator
instructions do not drift across documents.
