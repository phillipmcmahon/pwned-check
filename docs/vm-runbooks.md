# VM Runbooks

These runbooks describe how to rebuild or refresh the persistent release
validation guests. They are maintainer-facing and intentionally omit IP
addresses, passwords, private SSH keys, NAS credentials, and hypervisor details.

Codex may access only explicitly provided `codex-vm-*` guests. Do not use
Codex to access the hypervisor, host console, storage backend, or VM management
plane. If a VM cannot be repaired through normal SSH to the guest, hand recovery
back to the maintainer.

## Common Baseline

Every VM should have:

- a `codex` account reachable through an SSH alias in maintainer-local
  `~/.ssh/config`
- key-based SSH for normal access
- passwordless `sudo -n true` for the `codex` account
- no GitHub credentials, repository signing private keys, VM passwords, or NAS
  credentials copied to the guest
- a checkout under `/home/codex/pwned-check`, refreshed from the maintainer
  workstation by the smoke scripts or by `rsync`

Bootstrap checks:

```bash
ssh codex-vm-<distro> 'uname -m && cat /etc/os-release && sudo -n true'
```

Sync expectation:

```bash
rsync -a --delete --exclude .git --exclude .test-output --exclude dist \
  ./ codex-vm-<distro>:/home/codex/pwned-check/
```

The validation scripts may also copy a prebuilt static Linux `pwned-check`
binary into `/tmp/pwned-check-vm-prebuilt/` so package smokes do not require a
matching Go toolchain on every guest.

## Ubuntu

Host aliases: `codex-vm-ubuntu` (`amd64`) and `codex-vm-ubuntu-arm64`
(`arm64`)

Purpose: Ubuntu `.deb` package behavior, Debian-family native PAM harness,
hardening assessment, and apt repository smoke.

Bootstrap packages:

```bash
ssh codex-vm-ubuntu 'sudo apt-get update && sudo apt-get install -y build-essential ca-certificates clang curl file gcc git golang-go libpam0g-dev make pkg-config rsync'
ssh codex-vm-ubuntu 'if [ ! -x "$HOME/.cargo/bin/rustup" ]; then curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; fi; ~/.cargo/bin/rustup default stable'
ssh codex-vm-ubuntu-arm64 'sudo apt-get update && sudo apt-get install -y build-essential ca-certificates clang curl file gcc git golang-go libpam0g-dev make pkg-config rsync cargo rustfmt jq tar gzip xz-utils'
ssh codex-vm-ubuntu-arm64 'if [ ! -x "$HOME/.cargo/bin/rustup" ]; then curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; fi; ~/.cargo/bin/rustup default stable'
```

Primary smokes:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:/usr/sbin:/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-deb-package-smoke'
ssh codex-vm-ubuntu-arm64 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:/usr/sbin:/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-deb-package-smoke'
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-ubuntu --repo-url https://phillipmcmahon.github.io/pwned-check/apt
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-ubuntu-arm64 --repo-url https://phillipmcmahon.github.io/pwned-check/apt
```

Recovery checks:

- `sudo pwned-check-pam-disable || true`
- `sudo env DEBIAN_FRONTEND=noninteractive dpkg -r pwned-check-native-pam || true`
- verify `/etc/pam.d/common-password` no longer references `pam_pwned_check.so`

Known quirks:

- Ubuntu has Rust through rustup in the `codex` home directory; keep
  `$HOME/.cargo/bin` ahead of the system path for native PAM builds.
- `.deb` removal can warn that the distro PAM security directory is not empty;
  that is expected because the directory is owned by the OS.

## Debian

Host aliases: `codex-vm-debian` (`amd64`) and `codex-vm-debian-arm64`
(`arm64`)

Purpose: Debian `.deb` package behavior, Debian-family native PAM harness, and
apt repository smoke.

Bootstrap packages:

```bash
ssh codex-vm-debian 'sudo apt-get update && sudo apt-get install -y ca-certificates curl gcc libc6-dev libpam0g-dev make pkg-config golang-go cargo rustfmt file tar gzip xz-utils jq rsync'
ssh codex-vm-debian-arm64 'sudo apt-get update && sudo apt-get install -y ca-certificates curl gcc libc6-dev libpam0g-dev make pkg-config golang-go cargo rustfmt file tar gzip xz-utils jq rsync'
```

Primary smokes:

```bash
ssh codex-vm-debian 'cd /home/codex/pwned-check && PATH="/usr/sbin:/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-deb-package-smoke'
ssh codex-vm-debian-arm64 'cd /home/codex/pwned-check && PATH="/usr/sbin:/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-deb-package-smoke'
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-debian --repo-url https://phillipmcmahon.github.io/pwned-check/apt
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-debian-arm64 --repo-url https://phillipmcmahon.github.io/pwned-check/apt
```

Recovery checks:

- `sudo pwned-check-pam-disable || true`
- `sudo env DEBIAN_FRONTEND=noninteractive dpkg -r pwned-check-native-pam || true`
- verify `pam-auth-update` is available on `PATH`; use `/usr/sbin` for SSH
  sessions

Known quirks:

- Debian SSH sessions may not include `/usr/sbin`; prepend it for
  `pam-auth-update`.
- If stale local virtualenv directories cause `rsync --delete` warnings, remove
  them on the guest before release validation. They are not release state.

## Fedora

Host aliases: `codex-vm-fedora` (`x86_64`) and `codex-vm-fedora-arm64`
(`arm64`)

Purpose: Fedora RPM package behavior, authselect mode switching, SELinux
assessment, and RPM repository smoke.

Bootstrap packages:

```bash
ssh codex-vm-fedora 'sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools rpmlint tar gzip xz findutils diffutils jq policycoreutils selinux-policy-devel setools-console rsync'
ssh codex-vm-fedora-arm64 'sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools rpmlint tar gzip xz findutils diffutils jq policycoreutils selinux-policy-devel setools-console rsync'
```

Primary smokes:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment'
ssh codex-vm-fedora-arm64 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment'
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-fedora --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-fedora-arm64 --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
```

Recovery checks:

- `sudo pwned-check-pam-disable || true`
- `sudo rpm -e pwned-check-native-pam || true`
- `authselect current` should not remain on a `custom/pwned-check-*` profile
  after rollback unless the smoke explicitly created and selected it

Known quirks:

- Fedora SELinux assessment is part of release evidence. A pwned-check-related
  AVC should fail the assessment or be tracked as an explicit exception.
- RPM package smokes must prove dry-run, enforcement, disable, package removal,
  and authselect backup restoration.

## Rocky

Host aliases: `codex-vm-rocky` (`x86_64`) and `codex-vm-rocky-arm64`
(`arm64`)

Purpose: RHEL-compatible RPM package behavior, authselect mode switching,
SELinux assessment, and RPM repository smoke.

Bootstrap packages:

```bash
ssh codex-vm-rocky 'sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools tar gzip xz findutils diffutils jq policycoreutils selinux-policy-devel setools-console rsync'
ssh codex-vm-rocky-arm64 'sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools tar gzip xz findutils diffutils jq policycoreutils selinux-policy-devel setools-console rsync'
```

Primary smokes:

```bash
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment'
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-rocky --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
ssh codex-vm-rocky-arm64 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment'
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-rocky-arm64 --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
```

Recovery checks:

- `sudo pwned-check-pam-disable || true`
- `sudo rpm -e pwned-check-native-pam || true`
- verify authselect has returned to the pre-smoke profile

Known quirks:

- Rocky validation must run on the matching Rocky VM; do not substitute the
  Rocky Docker image for local acceptance when the VM is available.

## Alpine

Host aliases: `codex-vm-alpine` (`x86_64`) and `codex-vm-alpine-arm64`
(`arm64`)

Purpose: Alpine Linux-PAM package behavior, manual PAM helper rollback, and
Alpine repository smoke for published `aarch64` content.

Bootstrap packages:

```bash
ssh codex-vm-alpine 'sudo apk update && sudo apk add --no-cache ca-certificates cargo clang file gcc git go linux-pam linux-pam-dev make musl-dev pkgconf rust rustfmt tar gzip xz findutils diffutils jq shadow sudo doas rsync'
ssh codex-vm-alpine-arm64 'sudo sed -i "s|^#\\(http://dl-cdn.alpinelinux.org/alpine/v3.23/community\\)|\\1|" /etc/apk/repositories && sudo apk update && sudo apk add alpine-sdk bash ca-certificates cargo clang file gcc git go libc-dev linux-pam-dev make musl-dev openssl-dev pkgconf rsync rust rustfmt tar xz zstd'
```

Primary smokes:

```bash
ssh codex-vm-alpine 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols'
PWNED_CHECK_VM_SMOKE_HOSTS=codex-vm-alpine PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh
PWNED_CHECK_VM_SMOKE_HOSTS=codex-vm-alpine-arm64 PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh
```

Repository smoke:

```bash
./scripts/native-pam-alpine-repo-smoke.sh --host codex-vm-alpine-arm64 --repo-url https://phillipmcmahon.github.io/pwned-check/alpine
```

Recovery checks:

- `sudo pwned-check-pam-disable || true`
- `sudo apk del pwned-check-native-pam || true`
- verify the disposable Linux-PAM service used by manual helper smokes has been
  removed or restored

Known quirks:

- Alpine support is for Linux-PAM deployments, not BusyBox-only authentication
  paths.
- Current published Alpine repository content is `aarch64`; use
  `codex-vm-alpine-arm64` for live endpoint install smoke. The `x86_64` VM
  remains useful for package-script and loader-path regression checks when a
  matching local APK is built.
- Alpine module placement varies by release; package and dependency checks
  cover both observed loader paths.

## Arch

Host alias: `codex-vm-arch`

Purpose: Arch package behavior, manual PAM helper rollback, and Arch custom
repository smoke.

Bootstrap packages:

```bash
ssh codex-vm-arch 'sudo pacman -Sy --needed --noconfirm base-devel ca-certificates curl file git go jq linux-pam make openssl pkgconf rsync rust tar xz zstd'
```

Primary smokes:

```bash
ssh codex-vm-arch 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols'
PWNED_CHECK_VM_SMOKE_HOSTS=codex-vm-arch PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh
./scripts/native-pam-arch-repo-smoke.sh --host codex-vm-arch --repo-url https://phillipmcmahon.github.io/pwned-check/arch
```

Recovery checks:

- `sudo pwned-check-pam-disable || true`
- `sudo pacman -Rns --noconfirm pwned-check-native-pam || true`
- verify the disposable Linux-PAM service used by manual helper smokes has been
  removed or restored

Known quirks:

- Arch package helpers install under `/usr/bin`, not `/usr/sbin`, to match Arch
  filesystem ownership expectations.
- Arch Linux packaging is `x86_64` only for this project.

## After Rebuild

After rebuilding or repairing any VM:

1. Run the bootstrap check.
2. Run the distro's primary package smoke.
3. Run the relevant repository smoke if a matching published architecture
   exists.
4. Confirm package removal and PAM/authselect rollback.
5. Record unusual recovery steps in this document or
   [Distro testing runbook](distro-testing.md) if they are likely to recur.
