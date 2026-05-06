# Package Repositories

This maintainer reference covers signed package repositories for the native
Linux PAM package. Operators should start with [Linux install](linux-install.md).

Repository-backed releases must satisfy the production release gate in
[Release playbook](release-playbook.md#release-gate).

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
| Alpine | `scripts/build-native-pam-alpine-repository.sh` | `APKINDEX.tar.gz`, `APKINDEX.tar.gz.sig`, packages, public RSA key |

Metadata and package payloads are immutable for a published version. Publish a
new patch version for payload corrections.

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

## Apt

Build:

```bash
scripts/build-native-pam-apt-repository.sh \
  --version vX.Y.Z \
  --packages dist/release \
  --output-dir dist/repositories/apt \
  --signing-key <openpgp-key-id>
```

Operator trust bootstrap:

```bash
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://phillipmcmahon.github.io/pwned-check/apt/pwned-check.asc \
  | sudo tee /etc/apt/keyrings/pwned-check.asc >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/pwned-check.asc] https://phillipmcmahon.github.io/pwned-check/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/pwned-check.list
sudo apt update
sudo apt install pwned-check-native-pam
```

## RPM

Build:

```bash
scripts/build-native-pam-rpm-repository.sh \
  --version vX.Y.Z \
  --packages dist/release \
  --output-dir dist/repositories/rpm \
  --signing-key <openpgp-key-id>
```

Operator trust bootstrap:

```bash
sudo tee /etc/yum.repos.d/pwned-check-native-pam.repo >/dev/null <<'EOF'
[pwned-check-native-pam]
name=pwned-check native PAM
baseurl=https://phillipmcmahon.github.io/pwned-check/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://phillipmcmahon.github.io/pwned-check/rpm/pwned-check.asc
EOF
sudo dnf install pwned-check-native-pam
```

## Arch

Build:

```bash
scripts/build-native-pam-arch-repository.sh \
  --version vX.Y.Z \
  --packages dist/release \
  --output-dir dist/repositories/arch \
  --signing-key <openpgp-key-id>
```

Operator trust bootstrap:

```bash
curl -fsSLO https://phillipmcmahon.github.io/pwned-check/arch/pwned-check.asc
sudo pacman-key --add pwned-check.asc
sudo pacman-key --lsign-key <fingerprint>
sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'
[pwned-check]
Server = https://phillipmcmahon.github.io/pwned-check/arch
SigLevel = Required DatabaseRequired
EOF
sudo pacman -Sy pwned-check-native-pam
```

## Alpine

Build:

```bash
scripts/build-native-pam-alpine-repository.sh \
  --version vX.Y.Z \
  --packages dist/release \
  --output-dir dist/repositories/alpine \
  --signing-key <rsa-private-key>
```

Operator trust bootstrap:

```bash
sudo install -d -m 0755 /etc/apk/keys
curl -fsSL https://phillipmcmahon.github.io/pwned-check/alpine/pwned-check-alpine-production.rsa.pub \
  | sudo tee /etc/apk/keys/pwned-check-alpine-production.rsa.pub >/dev/null
echo "https://phillipmcmahon.github.io/pwned-check/alpine" \
  | sudo tee -a /etc/apk/repositories
sudo apk update
sudo apk add pwned-check-native-pam
```
