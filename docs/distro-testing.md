# Distro Testing Runbook

This runbook covers Linux distro validation for both supported integration paths:

- the existing `pam_exec.so expose_authtok` helper package
- the native `pam_pwned_check.so` module and its distro package layouts

Keep Git and GitHub operations in the main development environment. Persistent VMs are test execution targets only.

Operator access is limited to the `codex-vm-*` hosts that have been explicitly
provided for testing. Do not log in to, inspect, modify, or recover through the
hypervisor or any other infrastructure host. If a VM becomes unreachable or its
privileged access is broken, stop and ask for the VM to be repaired, recreated,
or made available again through the normal `codex-vm-*` SSH path.

## Coverage Layers

Use the cheapest layer that can prove the behavior under test, then move outward when packaging or host integration is involved.

| Layer | Environment | What it proves |
|---|---|---|
| Unit and host build gates | Local checkout | Go behavior, Rust module behavior, exported PAM symbols, dependency allowlist on the current host |
| Docker binary smoke | Throwaway distro containers | Static Linux binaries run across minimal distro images |
| Docker PAM package smoke | Throwaway distro containers | Helper package install, `pam_exec.so expose_authtok`, helper exit-code mapping, timeout and config-error behavior |
| Docker native PAM distro smoke | Throwaway distro containers | Distro toolchain can build/load `pam_pwned_check.so`, direct clean and pwned `pam_chauthtok` outcomes work |
| Docker generic native package smoke | Throwaway Arch/Alpine containers | CI/fallback generic artifact installs, manual PAM helper enables, direct native PAM outcomes work, rollback restores the service |
| Persistent Ubuntu smoke container | Reused Ubuntu container | Fast native PAM development loop with captured logs, syslog, exact conversation strings, checker environment, Debian/Ubuntu artifact enable/rollback |
| Persistent distro VMs | Real distro hosts | Host package layout, package tooling, distro-specific module directory/dependency drift, enablement and rollback against a real system |

## Canonical Distro Set

The first-wave distro set is:

| Family | Primary target | Docker image | Persistent VM status |
|---|---|---|---|
| Debian | Debian stable | `debian:stable-slim` | `codex-vm-debian` (Debian 13) |
| Ubuntu | Ubuntu 24.04 | `ubuntu:24.04` | `codex-vm-ubuntu` |
| Fedora | Fedora current | `fedora:latest` | `codex-vm-fedora` |
| RHEL-compatible | Rocky Linux 10 | `rockylinux/rockylinux:10.1` for arm64 CI parity only | `codex-vm-rocky` |
| Arch Linux | Rolling | `archlinux:base-devel` | `codex-vm-arch` |
| Alpine Linux | Alpine with Linux-PAM | `alpine:3.22` | `codex-vm-alpine` |

Do not check VM passwords, IP addresses, or generated private keys into the repository. Store SSH aliases in `~/.ssh/config` and rotated emergency passwords outside the checkout.

## Docker Test Commands

Local `linux/amd64` validation is VM-first. Do not run amd64 Docker locally as
routine coverage when the matching persistent VM exists. Use amd64 Docker only
when intentionally reproducing CI behavior or when a persistent VM is
unavailable.

```bash
./scripts/docker-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/docker-pam-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
```

Local `linux/arm64` validation uses Docker to reduce the gap with GitHub CI:

```bash
./scripts/docker-smoke.sh --platform linux/arm64 --images "debian:stable-slim ubuntu:24.04 fedora:latest rockylinux/rockylinux:10.1 alpine:3.22"
./scripts/docker-pam-smoke.sh --platform linux/arm64 --images "debian:stable-slim ubuntu:24.04 fedora:latest rockylinux/rockylinux:10.1 alpine:3.22"
```

The default amd64 Docker matrix used by GitHub CI is:

```text
debian:stable-slim ubuntu:24.04 fedora:latest archlinux:base-devel alpine:3.22
```

Rocky Linux testing is performed on `codex-vm-rocky`; do not use the
`rockylinux` Docker image for local amd64 Rocky validation. The
`rockylinux/rockylinux:10.1` image is used for arm64 Docker smoke because the
project does not have a persistent arm64 Rocky VM.

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
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64 --images "alpine:3.22"
```

Arch is omitted from local and CI arm64 Docker smoke because
`archlinux:base-devel` does not currently publish a suitable arm64 image.

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
- connect only to explicitly provided `codex-vm-*` SSH hosts
- do not access the hypervisor, host console, storage backend, or VM management plane
- if VM recovery requires hypervisor, console, rescue, or disk access, stop and hand the recovery back to the operator
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

## Debian VM

Install dependencies:

```bash
ssh codex-vm-debian 'sudo apt-get update && sudo apt-get install -y ca-certificates curl gcc libc6-dev libpam0g-dev make pkg-config golang-go cargo rustfmt file tar gzip xz-utils jq rsync'
```

Core native PAM gates:

```bash
ssh codex-vm-debian 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness'
```

Debian/Ubuntu package-layout and `.deb` smoke:

```bash
ssh codex-vm-debian 'cd /home/codex/pwned-check && PATH="/usr/sbin:$PATH" make native-pam-ubuntu-host-package-smoke native-pam-ubuntu-deb-package-smoke'
```

On Debian 13, `pam-auth-update` is installed under `/usr/sbin`, which is not always in the non-root `codex` user's default PATH. Keep the explicit `PATH="/usr/sbin:$PATH"` prefix when running package smoke commands over SSH.

The Debian VM validates the Debian/Ubuntu filesystem layout and native `.deb` package behavior on a real Debian host. The same script names retain `ubuntu` because the package path covers the shared Debian/Ubuntu `pam-auth-update` integration.

Debian/Ubuntu apt repository smoke:

```bash
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-ubuntu
./scripts/native-pam-apt-repo-smoke.sh --host codex-vm-debian
```

Run this after `dist/apt-repository` has been generated with
`scripts/build-native-pam-apt-repository.sh`. The target VM receives only the
repository files and public key, installs through apt, exercises the packaged
dry-run/enforce/disable helpers, purges the package, and verifies managed-file
cleanup. Each run writes a combined report under
`.test-output/native-pam-apt-repo-smoke/<timestamp>-native-pam-apt-repo-smoke/`
and updates `.test-output/native-pam-apt-repo-smoke/latest`.

## Debian Docker Route

The Debian Docker route remains the cheap, disposable coverage path. Run the Debian slices of the binary, helper PAM, and direct native PAM smoke tests:

```bash
./scripts/docker-smoke.sh --platform linux/amd64 --images "debian:stable-slim"
./scripts/docker-pam-smoke.sh --platform linux/amd64 --images "debian:stable-slim"
./scripts/native-pam-distro-smoke.sh --platform linux/amd64 --images "debian:stable-slim"
```

Use this route for quick regressions and CI parity. Use `codex-vm-debian` before release or whenever the Debian/Ubuntu package enablement, rollback, or `pam-auth-update` behavior changes.

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

## Rocky VM

Rocky testing runs on `codex-vm-rocky`. Do not substitute the `rockylinux`
Docker image for Rocky validation when the VM is available.

Install dependencies:

```bash
ssh codex-vm-rocky 'sudo dnf install -y ca-certificates cargo clang file gcc gcc-c++ git golang make pam-devel pkgconf-pkg-config rust rustfmt authselect rpm-build rpmdevtools tar gzip xz findutils diffutils jq policycoreutils selinux-policy-devel setools-console rsync'
```

Core native PAM and RPM-family package gates:

```bash
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols package-native-pam-rpm'
```

Host package and authselect smoke:

```bash
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-fedora-host-package-smoke'
```

RPM package smoke:

```bash
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-fedora-rpm-package-smoke'
```

SELinux assessment:

```bash
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-fedora-selinux-assessment'
```

Rocky packages may lag the repository's Go version. If Rocky cannot build the
`pwned-check` helper because its packaged Go is too old, build a static Linux
helper in the main development environment and copy it in:

```bash
mkdir -p /tmp/pwned-check-rocky-prebuilt
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
  -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=rocky-vm-smoke" \
  -o /tmp/pwned-check-rocky-prebuilt/pwned-check ./cmd/pwned-check
ssh codex-vm-rocky 'mkdir -p /tmp/pwned-check-rocky-prebuilt'
scp /tmp/pwned-check-rocky-prebuilt/pwned-check codex-vm-rocky:/tmp/pwned-check-rocky-prebuilt/pwned-check
ssh codex-vm-rocky 'chmod 0755 /tmp/pwned-check-rocky-prebuilt/pwned-check'
ssh codex-vm-rocky 'cd /home/codex/pwned-check && ./scripts/package-native-pam-rpm-package.sh --version rocky-vm-smoke --pwned-check-bin /tmp/pwned-check-rocky-prebuilt/pwned-check'
ssh codex-vm-rocky 'cd /home/codex/pwned-check && PWNED_CHECK_HOST_SMOKE_PWNED_CHECK_BIN=/tmp/pwned-check-rocky-prebuilt/pwned-check ./scripts/native-pam-fedora-host-package-smoke.sh'
ssh codex-vm-rocky 'cd /home/codex/pwned-check && PWNED_CHECK_FEDORA_RPM_SMOKE_PWNED_CHECK_BIN=/tmp/pwned-check-rocky-prebuilt/pwned-check ./scripts/native-pam-fedora-rpm-package-smoke.sh'
ssh codex-vm-rocky 'cd /home/codex/pwned-check && PWNED_CHECK_HOST_SMOKE_PWNED_CHECK_BIN=/tmp/pwned-check-rocky-prebuilt/pwned-check make native-pam-fedora-selinux-assessment'
```

The Rocky VM validates the RHEL-compatible package path against a real host:
`authselect` profile creation, dry-run and enforce helper switching, rollback,
package removal, dependency drift, and SELinux/audit behavior. The scripts keep
their `fedora` names because they cover the shared Fedora/RHEL/Rocky package
family.

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

Build and smoke the native APK package on the VM:

```bash
ssh codex-vm-alpine 'cd /home/codex/pwned-check &&
  if apk info -e pwned-check-native-pam >/dev/null 2>&1; then sudo apk del pwned-check-native-pam; fi &&
  apk_name="$(./scripts/package-native-pam-alpine-package.sh --version 0.0.0 --pwned-check-bin /tmp/pwned-check-alpine-prebuilt/pwned-check)" &&
  sudo apk add --allow-untrusted "dist/release/$apk_name" &&
  ./scripts/native-pam-manual-installed-smoke.sh &&
  sudo apk del pwned-check-native-pam'
```

Alpine Linux-PAM module placement varies by release. The persistent Alpine VM
loads from `/usr/lib/security`, while the pinned `alpine:3.22` Docker image
loads from `/lib/security`. The Alpine package installs `pam_pwned_check.so`
in both locations for first-release compatibility:

```text
/usr/lib/security
/lib/security
```

The dependency allowlist must accept musl's libc name:

```text
libc.musl-*.so.*
```

Alpine package smoke should run on `codex-vm-alpine` for release validation. Use the Docker route only as fallback coverage when the VM is unavailable:

```bash
./scripts/native-pam-alpine-package-smoke.sh --platform linux/amd64
```

The Alpine package smoke builds an `APKBUILD` package, installs it with `apk`, verifies the package file list, exercises dry-run/enforce/disable through the manual PAM helper wrappers, removes the package, and verifies package-managed files are gone.

Alpine repository smoke:

```bash
./scripts/native-pam-alpine-repo-smoke.sh --host codex-vm-alpine
```

Run this after `dist/alpine-repository` has been generated with
`scripts/build-native-pam-alpine-repository.sh`. The target VM receives only the
repository files and RSA public key, installs through apk without
`--allow-untrusted`, exercises packaged dry-run/enforce/disable helpers on a
disposable Linux-PAM service, removes the package, and verifies managed-file
cleanup. Each run writes a combined report under
`.test-output/native-pam-alpine-repo-smoke/<timestamp>-native-pam-alpine-repo-smoke/`
and updates `.test-output/native-pam-alpine-repo-smoke/latest`.

## Arch VM Route

Arch package smoke should run on `codex-vm-arch` for local and release
validation. The pre-push hook syncs the checkout to the VM, removes any
previous `pwned-check-native-pam` install, builds the Arch package with
`makepkg`, installs it with `pacman -U`, runs the installed native PAM manual
smoke, removes the package, and verifies rollback and managed-file cleanup.

To run the Arch VM package smoke manually:

```bash
PWNED_CHECK_VM_SMOKE_ONLY=1 \
PWNED_CHECK_VM_SMOKE_HOSTS=codex-vm-arch \
./scripts/validate-before-push.sh
```

Use the Arch Docker path only for GitHub CI parity or when the VM is
unavailable:

```bash
./scripts/native-pam-distro-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/native-pam-generic-package-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
./scripts/native-pam-arch-package-smoke.sh --platform linux/amd64
```

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
PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh
```

Before claiming a distro package path is ready:

- run the matching persistent VM path for local release validation
- run the matching Docker path only when reproducing CI-only behavior or when a VM is unavailable
- verify install and rollback
- inspect dynamic dependencies with `ldd pam_pwned_check.so`
- record any new shared-library dependency in the allowlist and docs only after review

## CI And Release Gates

The heavy native PAM package gates run through the `Native PAM Package Gates` GitHub Actions workflow. It is scheduled weekly and can be started manually with `workflow_dispatch`.

Automated in that workflow:

- Ubuntu `.deb` package smoke on an ephemeral Ubuntu runner
- direct native PAM distro smoke across the first-wave Docker images
- generic manual-PAM package smoke across Arch and Alpine Docker images
- Arch `PKGBUILD` package smoke through Docker for CI parity
- Alpine `APKBUILD` package smoke through Docker
- arm64 native PAM release-asset smoke for Debian, Fedora, and Alpine package outputs

For local and release validation, use persistent VMs for first-wave amd64 distro
coverage. Use local arm64 Docker smoke for CI parity. Use amd64 Docker locally
only as fallback reproduction when a VM is unavailable or a GitHub-only failure
needs to be reproduced.

Smoke architecture coverage is split by runner capability:

| Distro | Local Default | Local Architecture | GitHub CI Docker | GitHub Package Gates |
|---|---|---|---|---|
| Debian | `codex-vm-debian` over SSH | VM is `linux/amd64`; `.deb` smoke runs from clean package state | Binary/PAM Docker smoke on `linux/amd64` and `linux/arm64` | arm64 Debian native PAM package asset smoke |
| Ubuntu | `codex-vm-ubuntu` over SSH | VM is `linux/amd64`; `.deb` smoke runs from clean package state | Binary/PAM Docker smoke on `linux/amd64` and `linux/arm64`; `.deb` smoke on `ubuntu-24.04` runner | Covered by Debian-family package asset path |
| Fedora | `codex-vm-fedora` over SSH | VM is `linux/amd64`; RPM smoke runs from clean package state | Binary/PAM Docker smoke on `linux/amd64` and `linux/arm64` | arm64 Fedora native PAM package asset smoke |
| Rocky | `codex-vm-rocky` over SSH | VM is `linux/amd64`; RPM smoke runs from clean package state | Binary/PAM Docker smoke on `linux/arm64` using `rockylinux/rockylinux:10.1`; amd64 Rocky acceptance is VM-first | Covered by Fedora/RHEL-family package scripts, plus arm64 Docker smoke for runtime/PAM parity |
| Alpine | `codex-vm-alpine` over SSH | VM is `linux/amd64`; APK smoke runs from clean package state | Binary/PAM Docker smoke on `linux/amd64` and `linux/arm64` | arm64 Alpine native PAM package asset smoke |
| Arch | `codex-vm-arch` over SSH | VM is `linux/amd64`; pacman smoke runs from clean package state | Binary/PAM Docker smoke and `PKGBUILD` package smoke on `linux/amd64` | No arm64 Arch smoke until an Arch Linux ARM image or VM is selected |

The pre-push hook runs the VM package smoke stage over SSH against the default
persistent VM set and, in the full validation path, runs local arm64 Docker
binary and PAM package smoke against Debian, Ubuntu, Fedora, Rocky, and Alpine:

```bash
./scripts/validate-before-push.sh
```

To run only the VM stage:

```bash
PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh
```

For deliberate offline work, skip the arm64 Docker stage explicitly:

```bash
PWNED_CHECK_SKIP_ARM64_DOCKER=1 ./scripts/validate-before-push.sh
```

Before running each package smoke, the hook disables and removes any existing
`pwned-check-native-pam` package on that VM. This keeps Ubuntu, Debian, Fedora,
Rocky, Alpine, and Arch on the same clean package-install validation path.

Use the host-specific commands below to rerun a single VM manually, to capture
release evidence, or to run gates that are intentionally not part of the default
pre-push VM stage, such as hardening and SELinux assessments:

```bash
ssh codex-vm-ubuntu 'cd /home/codex/pwned-check && PATH="$HOME/.cargo/bin:$PATH" make native-pam-ubuntu-deb-package-smoke native-pam-ubuntu-hardening-assessment'
ssh codex-vm-debian 'cd /home/codex/pwned-check && PATH="/usr/sbin:$PATH" make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness native-pam-ubuntu-host-package-smoke native-pam-ubuntu-deb-package-smoke'
ssh codex-vm-fedora 'cd /home/codex/pwned-check && make native-pam-fedora-selinux-assessment native-pam-fedora-rpm-package-smoke'
ssh codex-vm-rocky 'cd /home/codex/pwned-check && make native-pam-fedora-selinux-assessment native-pam-fedora-rpm-package-smoke'
ssh codex-vm-alpine 'cd /home/codex/pwned-check && make native-pam-test native-pam-build native-pam-deps native-pam-symbols'
```

The Fedora RPM and SELinux gates are not run on generic CI runners because the acceptance path validates real `authselect` selection, backup restoration, SELinux enforcing mode, and host rollback. Record their output in `.test-output/` or the release validation notes before release. Fedora package smokes must prove both `pwned-check-pam-enable-dry-run` and `pwned-check-pam-enable-enforce` before `pwned-check-pam-disable` restores the first-enable authselect backup.

Fedora/Rocky RPM repository smoke:

```bash
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-fedora
./scripts/native-pam-rpm-repo-smoke.sh --host codex-vm-rocky
```

Run this after `dist/rpm-repository` has been generated with
`scripts/build-native-pam-rpm-repository.sh`. The target VM receives only the
repository files and public key, installs through dnf/yum with package and
repository metadata signature checks enabled, exercises the packaged
dry-run/enforce/disable helpers, removes the package, and verifies managed-file
cleanup. Each run writes a combined report under
`.test-output/native-pam-rpm-repo-smoke/<timestamp>-native-pam-rpm-repo-smoke/`
and updates `.test-output/native-pam-rpm-repo-smoke/latest`.

## Current Observations

- Ubuntu host smoke validates the Debian/Ubuntu filesystem-layout artifact without modifying the real `common-password` stack.
- Ubuntu `.deb` package smoke validates native `pwned-check-native-pam` package install, file list, installed-file PAM behavior, `pwned-check-pam-enable-dry-run`, `pwned-check-pam-enable-enforce`, `pwned-check-pam-disable`, `common-password` restoration, package removal, and managed-file cleanup.
- Ubuntu hardening assessment captures AppArmor state and validates disposable-service lockout recovery without editing `common-password`.
- Debian 13 VM validation runs the native PAM unit/build/dependency/symbol/host harness gates plus the Debian/Ubuntu host package and `.deb` package smoke. On Debian, run package smoke commands with `PATH="/usr/sbin:$PATH"` so SSH sessions can find `pam-auth-update`.
- Fedora host validation caught `libeconf.so.*` as an expected PAM transitive dependency.
- Fedora RPM package smoke validates the native `pwned-check-native-pam` RPM install, file list, installed-file PAM behavior, authselect dry-run/enforce switching, package rollback, removal, and managed-file cleanup.
- Fedora 44 Server SELinux assessment passed in `Enforcing` mode on 2026-05-01: the Fedora host package/authselect smoke passed, authselect restored to `local with-silent-lastlog with-fingerprint`, and `ausearch -m AVC,USER_AVC` returned `<no matches>` for the assessment window.
- Alpine host validation caught the `libc.musl-*.so.*` dependency name and confirmed Linux-PAM module placement under `/usr/lib/security` for the VM and `/lib/security` for the pinned Docker image.
- Alpine package smoke validates native `APKBUILD` package build/install, installed-file PAM behavior, manual dry-run/enforce switching, rollback, package removal, and managed-file cleanup on the Alpine VM. Docker remains available only as fallback coverage when the VM is unavailable.
- Arch local validation now runs on `codex-vm-arch`; Docker coverage remains for direct native PAM loading, generic artifact install/enable/rollback, and native `PKGBUILD` package build/install/dry-run/enforce/rollback/removal in CI/fallback contexts. Arch packages install `pwned-check-pam-*` wrappers under `/usr/bin` to avoid conflicting with Arch's `/usr/sbin` ownership model.
- Debian Docker coverage remains available for binary smoke, helper PAM package smoke, and direct native PAM loading against `debian:stable-slim`.
