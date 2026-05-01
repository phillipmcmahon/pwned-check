# Distro Testing Runbook

This runbook covers Linux distro validation for both supported integration paths:

- the existing `pam_exec.so expose_authtok` helper package
- the native `pam_pwned_check.so` module and its distro package layouts

Keep Git and GitHub operations in the main development environment. Persistent VMs are test execution targets only.

## Coverage Layers

Use the cheapest layer that can prove the behavior under test, then move outward when packaging or host integration is involved.

| Layer | Environment | What it proves |
|---|---|---|
| Unit and host build gates | Local checkout | Go behavior, Rust module behavior, exported PAM symbols, dependency allowlist on the current host |
| Docker binary smoke | Throwaway distro containers | Static Linux binaries run across minimal distro images |
| Docker PAM package smoke | Throwaway distro containers | Helper package install, `pam_exec.so expose_authtok`, helper exit-code mapping, timeout and config-error behavior |
| Docker native PAM distro smoke | Throwaway distro containers | Distro toolchain can build/load `pam_pwned_check.so`, direct clean and pwned `pam_chauthtok` outcomes work |
| Docker generic native package smoke | Throwaway Arch/Alpine containers | Generic artifact installs, manual PAM helper enables, direct native PAM outcomes work, rollback restores the service |
| Persistent Ubuntu smoke container | Reused Ubuntu container | Fast native PAM development loop with captured logs, syslog, exact conversation strings, checker environment, Debian/Ubuntu artifact enable/rollback |
| Persistent distro VMs | Real distro hosts | Host package layout, package tooling, distro-specific module directory/dependency drift, enablement and rollback against a real system |

## Canonical Distro Set

The first-wave distro set is:

| Family | Primary target | Docker image | Persistent VM status |
|---|---|---|---|
| Debian | Debian stable | `debian:stable-slim` | Docker route is accepted; no dedicated VM required |
| Ubuntu | Ubuntu 24.04 | `ubuntu:24.04` | `codex-vm-ubuntu` |
| Fedora | Fedora current | `fedora:latest` | `codex-vm-fedora` |
| RHEL-compatible | Rocky Linux 9 | `rockylinux:9` | Docker only for now |
| Arch Linux | Rolling | `archlinux:base-devel` | Docker only for now |
| Alpine Linux | Alpine with Linux-PAM | `alpine:3.20` | `codex-vm-alpine` |

Do not check VM passwords, IP addresses, or generated private keys into the repository. Store SSH aliases in `~/.ssh/config` and rotated emergency passwords outside the checkout.

## Docker Test Commands

Run the broad helper-package and binary matrix before changing release packaging:

```bash
./scripts/docker-smoke.sh --platform linux/amd64
./scripts/docker-pam-smoke.sh --platform linux/amd64
```

The default matrix is:

```text
debian:stable-slim ubuntu:24.04 fedora:latest rockylinux:9 archlinux:base-devel alpine:3.20
```

Run the direct native PAM module matrix when changing `native/pam-pwned-check`, shared-library dependency policy, or PAM module placement:

```bash
./scripts/native-pam-distro-smoke.sh --platform linux/amd64
```

Run the generic native package smoke when changing Arch or Alpine generic artifact behavior:

```bash
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64
```

Use a focused matrix while iterating:

```bash
./scripts/native-pam-distro-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64 --images "alpine:3.20"
```

On ARM Docker hosts, these commands may run under amd64 emulation. That is slower, but it keeps the matrix aligned with CI and release artifacts.

## Ubuntu Persistent Smoke Container

For native PAM development on Ubuntu, use the persistent container:

```bash
make native-pam-ubuntu-smoke
```

Useful commands:

```bash
./scripts/native-pam-ubuntu-smoke.sh shell
./scripts/native-pam-ubuntu-smoke.sh clean
```

Each run stores logs and case output under:

```text
.test-output/native-pam-ubuntu-smoke/<timestamp>-native-pam-ubuntu-smoke/
.test-output/native-pam-ubuntu-smoke/latest
```

The combined `.txt` file in each run directory is intended for quick preview. This output directory is ignored by Git.

## Persistent VM Setup

Each persistent VM should be prepared once, then reused for host package smoke tests.

Setup rules:

- user is `codex`
- install a dedicated SSH key for the VM
- rotate the bootstrap password after key login works
- configure passwordless sudo for `codex`
- install only build, package, and smoke-test dependencies
- keep repository syncs one-way from the development checkout to the VM
- do not run `gh`, commits, pushes, or release publishing from VMs

Generic onboarding checklist:

```bash
ssh codex@<host> 'id -un; cat /etc/os-release'
ssh-keygen -t ed25519 -f ~/.ssh/codex_vm_<distro>_ed25519 -N '' -C 'codex <distro> vm'
ssh-copy-id -i ~/.ssh/codex_vm_<distro>_ed25519.pub codex@<host>
ssh -i ~/.ssh/codex_vm_<distro>_ed25519 -o BatchMode=yes codex@<host> 'echo key-ok'
```

Rotate the password and add a sudoers drop-in using the distro's available privileged path. After setup, verify:

```bash
ssh codex-vm-<distro> 'sudo -n true && echo sudo-ok'
```

## VM Repository Sync

Sync the checkout before each VM run:

```bash
rsync -az --delete \
  --exclude .git \
  --exclude .test-output \
  --exclude build \
  --exclude dist \
  --exclude target \
  ./ codex-vm-<distro>:/home/codex/pwned-check/
```

Run commands with:

```bash
ssh codex-vm-<distro> 'cd /home/codex/pwned-check && <command>'
```

## Ubuntu VM

Install dependencies:

```bash
ssh codex-vm-ubuntu 'sudo apt-get update && sudo apt-get install -y build-essential ca-certificates clang curl file gcc git golang-go libpam0g-dev make pkg-config'
ssh codex-vm-ubuntu 'if [ ! -x "$HOME/.cargo/bin/rustup" ]; then curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal; fi; ~/.cargo/bin/rustup default stable'
```

Use `PATH="$HOME/.cargo/bin:$PATH"` for native PAM commands on Ubuntu. Ubuntu 24.04's distro Rust currently cannot parse this repository's Cargo lockfile format.

Core native PAM gates:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols package-native-pam-debian'
```

If using rustup as recommended above:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols package-native-pam-debian'
```

Host package smoke:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && make native-pam-ubuntu-host-package-smoke'
```

The host package smoke installs the Debian/Ubuntu filesystem layout, creates a disposable PAM service, exercises clean and pwned `pam_chauthtok` paths, and removes the installed files. It does not enable the package through the real `common-password` stack.

Debian package smoke:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && make native-pam-ubuntu-deb-package-smoke'
```

The `.deb` package smoke builds a native `pwned-check-native-pam` package through `dpkg-deb`, installs it through `dpkg`, verifies the package file list, exercises the installed files through the Ubuntu host smoke in installed-file mode, enables and disables the `pam-auth-update` profile, verifies `/etc/pam.d/common-password` is restored, removes the package, and verifies package-managed files are gone.

Hardening assessment:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:$PATH" make native-pam-ubuntu-hardening-assessment'
```

The hardening assessment wraps the `.deb` package smoke, captures AppArmor kernel/profile/journal state, and runs a lockout recovery drill through a disposable PAM service. The drill intentionally points `pam_pwned_check.so` at a missing checker, verifies the safe failure conversation, restores the service, and proves password-change flow succeeds again. It does not edit `common-password`.

Hardening assessment output is written to:

```text
.test-output/native-pam-ubuntu-hardening-assessment/<timestamp>-native-pam-ubuntu-hardening-assessment/
.test-output/native-pam-ubuntu-hardening-assessment/latest
```

If the Ubuntu test environment cannot build the Go checker itself, provide an existing Linux binary:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:$PATH" PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN=/tmp/pwned-check-ubuntu-prebuilt make native-pam-ubuntu-deb-package-smoke'
```

The lower-level filesystem-layout artifact remains available for staging and inspection:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && make package-native-pam-debian-artifact'
```

## Debian Docker Route

Debian is covered through Docker rather than a dedicated VM. Run the Debian slices of the binary, helper PAM, and direct native PAM smoke tests:

```bash
./scripts/docker-smoke.sh --platform linux/amd64 --images "debian:stable-slim"
./scripts/docker-pam-smoke.sh --platform linux/amd64 --images "debian:stable-slim"
./scripts/native-pam-distro-smoke.sh --platform linux/amd64 --images "debian:stable-slim"
```

The Ubuntu persistent smoke container and Ubuntu host package smoke continue to cover the shared Debian/Ubuntu `pam-auth-update` artifact behavior. A Debian VM may be added later for extra confidence, but it is not a release-blocking requirement for the current native PAM delivery track.

## Fedora VM

Install dependencies:

```bash
ssh codex-vm-fedora 'sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools rpmlint tar gzip xz findutils diffutils jq docker moby-engine podman policycoreutils selinux-policy-devel setools-console'
```

Core native PAM and RPM-family package gates:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols package-native-pam-rpm'
```

Host package and authselect smoke:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-fedora-host-package-smoke'
```

The host package smoke installs the RPM-family filesystem layout, creates a disposable PAM service for clean and pwned `pam_chauthtok` cases, enables the packaged authselect helper with a temporary `custom/pwned-check-smoke` profile, verifies the active `system-auth` and `password-auth` stacks contain the dry-run module line, restores the authselect backup, and removes installed test files.

RPM package smoke:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-fedora-rpm-package-smoke'
```

The RPM package smoke builds a native `pwned-check-native-pam` RPM through `rpmbuild`, installs it through `dnf` or `rpm`, verifies the RPM file list, exercises the installed files through the Fedora host smoke in installed-file mode, removes the RPM, and verifies package-managed files are gone.

The lower-level filesystem-layout artifact remains available for staging and inspection:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make package-native-pam-rpm-artifact'
```

If the Fedora test environment cannot build the Go checker itself, provide an existing Linux binary:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && PWNED_CHECK_HOST_SMOKE_PWNED_CHECK_BIN=/tmp/pwned-check-fedora-prebuilt make native-pam-fedora-host-package-smoke'
```

SELinux assessment:

```bash
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-fedora-selinux-assessment'
```

The assessment records a combined text report under:

```text
.test-output/native-pam-fedora-selinux-assessment/<timestamp>-native-pam-fedora-selinux-assessment/
.test-output/native-pam-fedora-selinux-assessment/latest
```

Acceptance for the Fedora/RHEL SELinux story is:

- the Fedora host package smoke passes
- SELinux is `Enforcing`, or the report explicitly states the host mode and the exception is tracked before production release
- audit AVC capture is present in the report
- no AVC lines mention `pwned-check`, `pam_pwned_check`, `pwned_check`, or the Fedora host smoke service
- the package decision remains operator-managed SELinux policy unless enforcing-mode evidence shows a common project policy is required

Fedora currently allows the following additional PAM transitive dependencies beyond the base Rust/C/PAM runtime set:

```text
libaudit.so.*
libcap-ng.so.*
libeconf.so.*
```

Unexpected `ldd dist/pam_pwned_check.so` additions should fail the dependency gate until reviewed.

## Alpine VM

Install dependencies:

```bash
ssh codex-vm-alpine 'sudo apk update && sudo apk add --no-cache ca-certificates cargo clang file gcc git go linux-pam linux-pam-dev make musl-dev pkgconf rust rustfmt tar gzip xz findutils diffutils jq shadow sudo doas rsync'
```

Core native PAM gates:

```bash
ssh codex-vm-alpine 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols'
```

Alpine packages may lag the repository's Go version. If Alpine cannot build the `pwned-check` helper because its packaged Go is too old, build a static Linux helper in the main development environment and copy it in:

```bash
mkdir -p /tmp/pwned-check-alpine-prebuilt
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=alpine-vm-smoke" \
  -o /tmp/pwned-check-alpine-prebuilt/pwned-check ./cmd/pwned-check
ssh codex-vm-alpine 'mkdir -p /tmp/pwned-check-alpine-prebuilt'
scp /tmp/pwned-check-alpine-prebuilt/pwned-check codex-vm-alpine:/tmp/pwned-check-alpine-prebuilt/pwned-check
ssh codex-vm-alpine 'chmod 0755 /tmp/pwned-check-alpine-prebuilt/pwned-check'
```

Build the Alpine generic artifact:

```bash
ssh codex-vm-alpine 'cd /home/codex/pwned-check && ./scripts/package-native-pam-generic-artifact.sh --version alpine-vm-smoke --family alpine --pwned-check-bin /tmp/pwned-check-alpine-prebuilt/pwned-check'
```

Alpine Linux-PAM loads security modules from:

```text
/lib/security
```

The dependency allowlist must accept musl's libc name:

```text
libc.musl-*.so.*
```

Alpine package smoke can run through Docker until the VM package path is needed:

```bash
./scripts/native-pam-alpine-package-smoke.sh --platform linux/amd64
```

The Alpine package smoke builds an `APKBUILD` package, installs it with `apk`, verifies the package file list, exercises the installed files through the manual PAM helper, removes the package, and verifies package-managed files are gone.

## Arch Docker Until VM Exists

Until a persistent Arch VM is available, use the Docker tests as the Arch acceptance path:

```bash
./scripts/native-pam-distro-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/native-pam-arch-package-smoke.sh --platform linux/amd64
```

These prove the Arch toolchain can build the module, the module loads from `/usr/lib/security`, the generic artifact installs, the `PKGBUILD` package builds and installs with `pacman`, manual enablement works, clean/pwned outcomes are correct, package removal cleans managed files, and rollback restores the disposable PAM service.

## When To Run What

Before committing native PAM implementation changes:

```bash
go test ./...
make native-pam-test
make native-pam-build
make native-pam-deps
make native-pam-symbols
./scripts/project-board-audit.sh
```

Before changing packaging or distro paths:

```bash
./scripts/docker-smoke.sh --platform linux/amd64
./scripts/docker-pam-smoke.sh --platform linux/amd64
./scripts/native-pam-distro-smoke.sh --platform linux/amd64
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64
```

Before claiming a distro package path is ready:

- run the matching Docker path
- run the matching persistent VM path when that distro uses a persistent VM in this runbook
- verify install and rollback
- inspect dynamic dependencies with `ldd pam_pwned_check.so`
- record any new shared-library dependency in the allowlist and docs only after review

## CI And Release Gates

The heavy native PAM package gates run through the `Native PAM Package Gates` GitHub Actions workflow. It is scheduled weekly and can be started manually with `workflow_dispatch`.

Automated in that workflow:

- Ubuntu `.deb` package smoke on an ephemeral Ubuntu runner
- direct native PAM distro smoke across the first-wave Docker images
- generic manual-PAM package smoke across Arch and Alpine Docker images
- Arch `PKGBUILD` package smoke through Docker
- Alpine `APKBUILD` package smoke through Docker

Host-specific release gates remain manual because they depend on persistent VM state and real host PAM management tools:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:$PATH" make native-pam-ubuntu-deb-package-smoke native-pam-ubuntu-hardening-assessment'
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-fedora-selinux-assessment native-pam-fedora-rpm-package-smoke'
ssh codex-vm-alpine 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols'
```

The Fedora RPM and SELinux gates are not run on generic CI runners because the acceptance path validates real `authselect` selection, backup restoration, SELinux enforcing mode, and host rollback. Record their output in `.test-output/` or the release validation notes before release.

## Current Observations

- Ubuntu host smoke validates the Debian/Ubuntu filesystem-layout artifact without modifying the real `common-password` stack.
- Ubuntu `.deb` package smoke validates native `pwned-check-native-pam` package install, file list, installed-file PAM behavior, `pam-auth-update` enable/disable, `common-password` restoration, package removal, and managed-file cleanup.
- Ubuntu hardening assessment captures AppArmor state and validates disposable-service lockout recovery without editing `common-password`.
- Fedora host validation caught `libeconf.so.*` as an expected PAM transitive dependency.
- Fedora RPM package smoke validates the native `pwned-check-native-pam` RPM install, file list, installed-file PAM behavior, authselect enable/rollback, package removal, and managed-file cleanup.
- Fedora 44 Server SELinux assessment passed in `Enforcing` mode on 2026-05-01: the Fedora host package/authselect smoke passed, authselect restored to `local with-silent-lastlog with-fingerprint`, and `ausearch -m AVC,USER_AVC` returned `<no matches>` for the assessment window.
- Alpine host validation caught the `libc.musl-*.so.*` dependency name and confirmed Linux-PAM module placement under `/lib/security`.
- Alpine package smoke validates native `APKBUILD` package build/install, installed-file PAM behavior, manual rollback, package removal, and managed-file cleanup through the Docker route.
- Arch currently has Docker coverage for direct native PAM loading, generic artifact install/enable/rollback, and native `PKGBUILD` package build/install/enable/rollback/removal.
- Debian coverage is Docker-first: binary smoke, helper PAM package smoke, and direct native PAM loading run against `debian:stable-slim`; no dedicated Debian VM is currently required.
