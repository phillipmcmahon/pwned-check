# Distro Testing

This is the maintainer runbook for Linux package validation. Operator install
steps live in [Linux install](linux-install.md); this file is only for package,
repository, VM, and Docker validation.

## Rules

- Test on persistent VMs when a matching VM exists. Local package acceptance
  must use the VM path for that distro and architecture.
- Use Docker for CI parity and for local reproduction, not as a substitute for
  an available VM acceptance path.
- Do not put GitHub credentials, signing keys, passphrases, NAS credentials, VM
  passwords, IP addresses, or hypervisor details in the repository.
- Codex may access only explicitly provided `codex-vm-*` guests. Codex is not
  authorized to log in to, inspect, modify, or recover through the hypervisor or
  any infrastructure host.
- Release signing and repository publication happen in the tag-triggered GitHub
  Actions release workflow. Maintainer-local repository generation is only a
  fallback path. Distro VMs never receive signing material or GitHub
  credentials.

## Coverage Matrix

| Family | Package | Local acceptance | Architectures |
|---|---|---|---|
| Debian/Ubuntu | Apt `.deb` | `codex-vm-ubuntu`, `codex-vm-debian`, `codex-vm-ubuntu-arm64`, `codex-vm-debian-arm64` | `amd64`, `arm64` |
| Fedora/Rocky | RPM | `codex-vm-fedora`, `codex-vm-rocky`, `codex-vm-fedora-arm64`, `codex-vm-rocky-arm64` | `x86_64`, `aarch64` |
| Arch | Pacman package | `codex-vm-arch` | `x86_64` only |
| Alpine Linux-PAM | APK | `codex-vm-alpine`, `codex-vm-alpine-arm64` | `x86_64`, `aarch64` |

Arch Linux ARM is a separate downstream ecosystem and is not targeted. Alpine
support is Linux-PAM only, not BusyBox-only authentication.

## VM Baseline

Every persistent VM should have:

- a `codex` account reachable through an SSH alias
- key-based SSH for normal access
- passwordless `sudo -n true`
- no release signing material or GitHub credentials
- a checkout at `/home/codex/pwned-check`, refreshed by smoke scripts or `rsync`
- current stable Rust and Cargo available to non-interactive SSH commands through
  `/usr/local/bin`; the native PAM harness must be able to read the committed
  `Cargo.lock` and build `pam_pwned_check.so` directly on every VM

Bootstrap check:

```bash
ssh codex-vm-<distro> 'uname -m && cat /etc/os-release && sudo -n true && cargo --version && rustc --version'
```

If a distro package ships an older Cargo than the repository lockfile requires,
install the current stable toolchain with `rustup` for the `codex` account and
publish it through `/usr/local/bin`:

```bash
ssh codex-vm-<distro> 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable'
ssh codex-vm-<distro> 'sudo ln -sf "$HOME/.cargo/bin/cargo" /usr/local/bin/cargo && sudo ln -sf "$HOME/.cargo/bin/rustc" /usr/local/bin/rustc'
```

Manual sync:

```bash
rsync -a --delete --exclude .git --exclude .test-output --exclude dist \
  ./ codex-vm-<distro>:/home/codex/pwned-check/
```

The pre-push validation script also copies a locally built static Linux
`pwned-check` binary to `/tmp/pwned-check-vm-prebuilt/` so VMs do not need a
matching Go toolchain for package smokes.

## Local Gate

Run all configured VM smokes:

```bash
./scripts/validate-before-push.sh
```

Run only the VM stage:

```bash
PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh
```

Run a selected VM subset:

```bash
PWNED_CHECK_VM_SMOKE_ONLY=1 \
PWNED_CHECK_VM_SMOKE_HOSTS="codex-vm-ubuntu codex-vm-fedora" \
  ./scripts/validate-before-push.sh
```

The smoke removes any existing `pwned-check-native-pam` package first, installs
the freshly built package, enables dry-run, switches to enforcement, disables,
removes the package, and checks managed-file cleanup.

## Repository Smoke

After package repositories are published, run:

```bash
make native-pam-live-repo-smokes
make native-pam-repo-endpoint-check
```

Family-specific repository smokes:

```bash
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-ubuntu --repo-url https://phillipmcmahon.github.io/pwned-check/apt
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-debian --repo-url https://phillipmcmahon.github.io/pwned-check/apt
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-fedora --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-rocky --repo-url https://phillipmcmahon.github.io/pwned-check/rpm
./scripts/native-pam-arch-repo-smoke.sh --host codex-vm-arch --repo-url https://phillipmcmahon.github.io/pwned-check/arch
./scripts/native-pam-alpine-repo-smoke.sh --host codex-vm-alpine --repo-url https://phillipmcmahon.github.io/pwned-check/alpine
```

Add the matching `*-arm64` host aliases for ARM repository coverage where the
family supports it.

## Docker Coverage

GitHub CI runs Docker smoke for binary behavior on `linux/amd64` and
`linux/arm64`. Tagged release asset preparation also builds packages in Docker
because GitHub-hosted runners do not have access to the maintainer VM fleet.
Local Docker smoke is optional when persistent VMs cover the same package path:

```bash
make docker-smoke
PWNED_CHECK_RUN_ARM64_DOCKER=1 ./scripts/validate-before-push.sh
```

Use local Docker primarily to reproduce CI failures or inspect container-only
release-builder behavior. Do not replace an available VM acceptance path with
Docker.

## Per-Family Commands

### Debian And Ubuntu

Bootstrap:

```bash
sudo apt-get update
sudo apt-get install -y build-essential ca-certificates clang curl file gcc git golang-go libpam0g-dev make pkg-config rsync cargo rustfmt jq tar gzip xz-utils
```

Primary smoke:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="/usr/local/bin:/usr/sbin:/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-deb-package-smoke'
ssh codex-vm-debian 'cd /home/codex/pwned-check && PATH="/usr/local/bin:/usr/sbin:/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-deb-package-smoke'
```

Recovery:

```bash
sudo pwned-check-pam-disable || true
sudo env DEBIAN_FRONTEND=noninteractive dpkg -r pwned-check-native-pam || true
grep -R pam_pwned_check.so /etc/pam.d || true
```

### Fedora And Rocky

Bootstrap:

```bash
sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools tar gzip xz findutils diffutils jq policycoreutils selinux-policy-devel setools-console rsync
```

Primary smoke:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment'
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-fedora-rpm-package-smoke native-pam-fedora-selinux-assessment'
```

Recovery:

```bash
sudo pwned-check-pam-disable || true
sudo rpm -e pwned-check-native-pam || true
authselect current
```

SELinux assessment is release evidence. A pwned-check-related AVC must fail the
assessment or be tracked explicitly.

### Alpine

Bootstrap:

```bash
sudo apk update
sudo apk add --no-cache alpine-sdk bash ca-certificates cargo clang file gcc git go linux-pam linux-pam-dev make musl-dev openssl-dev pkgconf rsync rust rustfmt tar xz zstd
```

Primary smoke:

```bash
PWNED_CHECK_VM_SMOKE_ONLY=1 \
PWNED_CHECK_VM_SMOKE_HOSTS="codex-vm-alpine codex-vm-alpine-arm64" \
  ./scripts/validate-before-push.sh
```

Recovery:

```bash
sudo pwned-check-pam-disable || true
sudo apk del pwned-check-native-pam || true
```

### Arch

Bootstrap:

```bash
sudo pacman -Sy --needed --noconfirm base-devel ca-certificates curl file git go jq linux-pam make openssl pkgconf rsync rust tar xz zstd
```

Primary smoke:

```bash
PWNED_CHECK_VM_SMOKE_ONLY=1 PWNED_CHECK_VM_SMOKE_HOSTS=codex-vm-arch ./scripts/validate-before-push.sh
```

Recovery:

```bash
sudo pwned-check-pam-disable || true
sudo pacman -Rns --noconfirm pwned-check-native-pam || true
```

## Recovery Expectations

VMs are disposable test capacity. Repository files, signing material, release
notes, and package artifacts must be recoverable from GitHub Releases, the
repository, and maintainer-controlled backup storage, not VM disks.

| Scenario | Response |
|---|---|
| Single VM lost | Recreate the guest, reapply SSH key/passwordless sudo, install bootstrap packages, rerun package and repository smoke. |
| Broken PAM or sudo | Do not use Codex for hypervisor recovery. Ask the maintainer to repair or recreate the guest. |
| Private infrastructure unavailable | Delay production release promotion or record an explicit architecture/distro deferral. |
| Local Docker unavailable | Skip local Docker only when matching VM smokes and GitHub CI coverage remain available. |

RTO target: a lost validation VM should be recreated within one maintainer
working session before production release promotion. RPO target: no release data
depends on VM disk state.
