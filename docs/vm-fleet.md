# VM Fleet

This document records the persistent VM expectations for release validation.
It is maintainer-facing; operator installation docs should not depend on these
hosts.

## Scope

The release-validation VMs live on private maintainer infrastructure. Treat the
fleet as disposable test capacity, not as a source of truth. Git operations,
GitHub authentication, release signing, and repository publication happen only
from the main development or signing environment.

Codex is authorized to access only explicitly named `codex-vm-*` guests that
the maintainer has provided. Codex is not authorized to log in to, inspect,
modify, or recover through the hypervisor or any infrastructure host. If a VM
is unavailable or privileged access is broken, stop and ask for that guest to be
repaired, recreated, or made available again through its `codex-vm-*` SSH path.

## Current Guests

| Host alias | Purpose | Architecture |
|---|---|---|
| `codex-vm-ubuntu` | Ubuntu package and apt repository smoke | `amd64` |
| `codex-vm-debian` | Debian package and apt repository smoke | `amd64` |
| `codex-vm-ubuntu-arm64` | Ubuntu package and apt repository smoke | `arm64` |
| `codex-vm-debian-arm64` | Debian package and apt repository smoke | `arm64` |
| `codex-vm-fedora` | Fedora RPM, authselect, SELinux, and repository smoke | `x86_64` |
| `codex-vm-fedora-arm64` | Fedora RPM, authselect, SELinux, and repository smoke | `arm64` |
| `codex-vm-rocky` | RHEL-compatible RPM, authselect, SELinux, and repository smoke | `x86_64` |
| `codex-vm-rocky-arm64` | RHEL-compatible RPM, authselect, SELinux, and repository smoke | `arm64` |
| `codex-vm-alpine` | Alpine Linux-PAM package smoke | `x86_64` |
| `codex-vm-alpine-arm64` | Alpine Linux-PAM package and repository smoke | `arm64` |
| `codex-vm-arch` | Arch package and repository smoke | `x86_64` |

Do not record VM passwords, IP addresses, private SSH keys, hypervisor
addresses, or NAS credentials in the repository. SSH aliases and emergency
credentials belong in maintainer-local storage.

## Missing Capacity

The current persistent fleet includes all targeted ARM package families:
Debian-family, Fedora, Rocky, and Alpine. Arch Linux is targeted as `x86_64`
only; Arch Linux ARM is a separate downstream ecosystem and is not part of the
current VM fleet plan.

Docker/QEMU coverage remains useful for CI parity and package-asset confidence,
but it is not a replacement for a persistent real-host repository smoke.

## Recovery Expectations

The VMs should be recoverable from distro installation media plus this
repository's runbooks. Use [VM runbooks](vm-runbooks.md) for per-distro
bootstrap packages, smoke commands, rollback checks, and known quirks. The VMs
should not contain irreplaceable release state.

| Scenario | Expected response |
|---|---|
| Single VM lost | Recreate the guest, reapply SSH key and passwordless sudo, install bootstrap packages from [VM runbooks](vm-runbooks.md), then rerun the matching package and repository smoke. |
| VM has broken PAM/sudo state | Do not attempt hypervisor recovery through Codex. Ask the maintainer to repair or recreate the guest, then rerun the relevant smoke from a clean package state. |
| Private infrastructure unavailable during a release window | Delay production release promotion or record an explicit deferral. Do not replace persistent VM acceptance with amd64 Docker when a VM exists for that distro. |
| Local Docker/QEMU unavailable | Local arm64 Docker is optional when arm64 VM smokes are configured. Set `PWNED_CHECK_RUN_ARM64_DOCKER=1` only when reproducing GitHub CI-parity behavior locally. |

RTO target: a lost amd64/x86_64 VM should be recreated within one maintainer
working session before a release is promoted. ARM VMs follow the same target.

RPO target: persistent VM state has no release-data value beyond the latest
smoke output. Repository artifacts, signing material, and release notes must be
recoverable from GitHub Releases, the repository, and maintainer-controlled
backup storage, not from VM disks.

## Capacity Planning

Before adding another distro or architecture, confirm:

- the host has enough CPU, memory, disk, and network capacity for parallel smoke
  runs without starving existing VMs
- the new VM has a clear owner, SSH alias, and entry in [VM runbooks](vm-runbooks.md)
- release gates identify whether the VM is mandatory or best-effort
- Docker fallback coverage is documented separately from real-host acceptance

If the fleet becomes too large for one maintainer to run comfortably, prefer
native CI runners or a smaller supported-distro matrix over hidden manual
dependencies.
