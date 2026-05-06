# Linux Production Baseline

v0.3.0 is the Linux production baseline for `pwned-check`.

The supported Linux operator path is:

1. Add the signed distro repository.
2. Install `pwned-check-native-pam`.
3. Enable dry-run.
4. Validate logs and rollback.
5. Switch to enforcement.

The single operator guide is [Linux package install](linux-install.md). GitHub
Release package assets remain immutable release artifacts for inspection,
recovery, and repository publication; signed package repositories are the normal
production install channel.

## Closeout Evidence

| EP11 story | Result | Evidence |
|---|---|---|
| EP11-S1: Post-maintenance CI baseline | Passed | Normal main CI passed for `006c645df878b6cb8b4f8772afbb860ba62f3d51`; local VM and package validation passed before closure. |
| EP11-S2: Single Linux install and enablement guide | Passed | [Linux package install](linux-install.md) is the operator front door; README and docs index route first-time users there. |
| EP11-S3: Signed v0.3 Linux release candidate | Passed | Signed tag `v0.3.0`, GitHub Release, checksums, provenance, and NAS archive were completed. |
| EP11-S4: Production release gate evidence | Passed | [v0.3.0 production gate evidence](releases/v0.3.0-production-gate.md) records signing, repository, validation, rollback, and documentation evidence. |
| EP11-S5: Repository install smoke matrix | Passed | Live repository install smokes passed on Ubuntu, Debian, Fedora, Rocky, Arch, and Alpine VMs across the published architectures. |
| EP11-S6: Linux production readiness declaration | Passed | README, operator docs, release notes, and roadmap now describe Linux as production-supported and keep non-Linux work separate. |

## Supported Linux Scope

| Family | Production repository support |
|---|---|
| Debian/Ubuntu | Apt `amd64` and `arm64` |
| Fedora/RHEL/Rocky | DNF/Yum `x86_64` and `aarch64` |
| Arch Linux | Pacman `x86_64` |
| Alpine Linux-PAM | APK `x86_64` and `aarch64` |

Arch Linux ARM is not targeted because it is a separate downstream ecosystem.
Alpine support requires Linux-PAM; BusyBox-only authentication is outside scope.

## Deferred Scope

macOS and Windows integration work is intentionally separate from the Linux
production baseline and remains tracked under Epic 7 or later platform-specific
epics. Do not treat this Linux readiness declaration as approval to ship macOS
or Windows password-change integrations.
