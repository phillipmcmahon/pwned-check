# Production Release Gate

This gate defines when native PAM distribution can be described as
production-ready. GitHub Release assets remain the immutable bootstrap and
recovery channel; signed package repositories are the normal production-style
operator install channel once this gate is satisfied for the release.

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

The repository tooling, production signing keys, GitHub Pages endpoints, and
repo-only smoke suites are implemented for the target families. Publication
evidence for the first production endpoint set is recorded in
[#39](https://github.com/phillipmcmahon/pwned-check/issues/39) and
`docs/releases/v0.1.6.md`.

Known architecture deferrals must be recorded in release notes before a release
is called production-ready. Apt `arm64`, RPM `aarch64`, and Alpine `aarch64`
now have native VM smoke coverage. Arch Linux is targeted as `x86_64` only.

## Signing Model

Signing happens in the release signing environment only. Private keys must not be stored in repo-tracked files, copied to persistent distro test VMs, embedded in smoke-test fixtures, or committed as encrypted blobs.

| Key material | Owner | Used for | Required controls |
|---|---|---|---|
| OpenPGP production key | Release maintainer or release signing runner owner | Apt `InRelease` and `Release.gpg`, RPM package signatures, optional RPM `repomd.xml` signatures, Arch package/database signatures, detached checksum/provenance signatures | One key for apt/RPM/Arch; private key outside the repo, GitHub Pages branch, and VMs; published fingerprint; documented rotation and revocation path. |
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

The release-time wrapper is:

```bash
make native-pam-live-repo-smokes
```

It runs the live published endpoint smokes for apt, RPM, Arch, and Alpine where
the project has persistent VMs today.

## Release Decision

A release may be called production-ready only when this gate passes and the release playbook records the evidence. If a criterion is deferred, the release notes must describe the release as pre-production or bootstrap-channel only, and the deferment must link to the relevant open story.
