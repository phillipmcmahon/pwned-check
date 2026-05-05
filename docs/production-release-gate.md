# Production Release Gate

This gate defines when native PAM distribution can be described as production-ready. Until every required item is satisfied, GitHub Release assets remain a bootstrap channel and signed package repositories remain a release-readiness track.

## Required Criteria

| Area | Required before production-ready release |
|---|---|
| Signing | Repository metadata is signed for apt, RPM, Arch, and Alpine; package signatures are present where the ecosystem expects them; checksum and provenance files are signed by the release signing key. |
| Repository publication | Apt, dnf/yum, Arch, and Alpine repositories are generated from the validated release package set and published without replacing package payloads at an existing version. |
| Smoke validation | Repository-only install smoke passes for every supported distro family using public repository configuration and public keys only. |
| Rollback validation | Every repository smoke covers dry-run enablement, enforcement, disable, package removal, and restoration of the affected PAM or authselect state. |
| Provider outage behavior | Fail-open and fail-closed behavior is validated through mocked provider outage tests before release, and operator docs explain how to switch posture during an outage. |
| Documentation | Operations, troubleshooting, repository setup, key rotation, revocation, and release notes describe the shipped channel accurately. |
| Board closeout | Epic 8 repository publication stories are closed or explicitly deferred with a rationale and linked production impact. |

Production readiness is blocked if any package repository requires GitHub credentials, build tools, private signing keys, or repository checkout state on the target distro host.

## Signing Model

Signing happens in the release signing environment only. Private keys must not be stored in repo-tracked files, copied to persistent distro test VMs, embedded in smoke-test fixtures, or committed as encrypted blobs.

| Key material | Owner | Used for | Required controls |
|---|---|---|---|
| OpenPGP release key | Release maintainer or release signing runner owner | Apt `InRelease` and `Release.gpg`, detached checksum/provenance signatures, optional Arch package signatures | Private key outside the repo and VMs; published fingerprint; documented rotation and revocation path. |
| RPM signing key | Release maintainer or release signing runner owner | RPM package signatures and optional `repomd.xml` signatures | RPM macros configured only in the signing environment; public key install instructions documented for Fedora/Rocky operators. |
| Alpine RSA key | Release maintainer or release signing runner owner | APK index and package trust for Alpine Linux-PAM repository installs | Private key outside the repo and VMs; public key distributed for `/etc/apk/keys`; rotation and compromised-key recovery documented. |

Public keys may be published after fingerprints, storage expectations, rotation cadence, revocation notice path, and operator update steps are documented. Existing package payloads must not be silently replaced after publication; publish a new patch version or a clearly versioned repository metadata correction instead. The operational key lifecycle is defined in [Package repositories](package-repositories.md#key-rotation-and-revocation).

## Repository-Only Smoke Gate

Repository smoke tests must install through the distro package manager using only:

- repository URL or source-list configuration
- public key material or fingerprint verification
- normal package manager commands
- the already published package metadata

The target host must not need `gh`, GitHub credentials, a local checkout, Cargo, Go, package build dependencies, or private signing keys. Build and signing work belongs in the release environment; distro VMs and containers consume the repository like operators would.

Required repository smoke coverage:

| Repository family | Required hosts | Required flow |
|---|---|---|
| Apt | Ubuntu and Debian VMs | Add public key and source list, `apt update`, install, enable dry-run, switch to enforcement, disable, remove package, verify managed-file cleanup. |
| DNF/Yum | Fedora and Rocky VMs | Add public key and repo file, install with `dnf`, run authselect dry-run/enforcement, disable, remove package, verify rollback, and keep SELinux assessment clean or tracked. |
| Arch | `codex-vm-arch` | Add custom repository and public key, install with `pacman -S`, run manual helper dry-run/enforcement, disable, remove package, verify managed-file cleanup. |
| Alpine | Alpine VM | Add public RSA key and repository URL, install with `apk add`, run manual helper dry-run/enforcement on a Linux-PAM service, disable, remove package, verify managed-file cleanup. |

## Release Decision

A release may be called production-ready only when this gate passes and the release playbook records the evidence. If a criterion is deferred, the release notes must describe the release as pre-production or bootstrap-channel only, and the deferment must link to the relevant open story.
