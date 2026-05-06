# Release Playbook

Use this checklist for public releases. The release process is intentionally simple while the project is pre-production.

## Rules

- Release from a clean `main` tree only.
- Validate from the actual release tree.
- Keep release notes operator-focused.
- Do not publish macOS or Windows production artifacts until signing requirements are addressed.
- Keep live HIBP calls out of release validation.
- Do not describe native PAM distribution as production-ready until the [Production release gate](production-release-gate.md) passes.

## Release Tracking

Create one release-prep issue for each release using the release-prep issue template.

The release issue should track:

- intended scope
- version metadata
- changelog entry
- validation results
- artifact names
- checksum generation
- project board reconciliation

## Checklist

### 1. Confirm Scope

- Decide which user-visible changes are shipping.
- Review related issues and project board entries.
- Update docs for changed behavior.
- Update `CHANGELOG.md`.

### 2. Prepare Version

- Update version metadata.
- Confirm the native PAM Rust crate version in `native/pam-pwned-check/Cargo.toml`
  and `Cargo.lock` matches the release tag without the leading `v`.
- Confirm `pwned-check --version` reports the intended version in the built binary.
- Keep release notes aligned with the actual shipped behavior.
- Write release-note validation entries in past tense once the checks have
  completed; avoid mixing planned validation with completed evidence.

### 3. Validate

Run:

```bash
make validate
```

Capture:

- `go test ./...`
- `make fuzz-release`
- `make coverage`
- `go vet ./...`
- `go run honnef.co/go/tools/cmd/staticcheck ./...`
- binary smoke test result
- Docker smoke matrix result
- CI `lint`, `staticcheck`, `test`, `smoke`, and `package-linux` jobs
- native PAM package, VM, and Docker validation results when shipping native PAM changes

For production-ready repository releases, also capture the [Production release gate](production-release-gate.md) evidence: signing status, repository-only install smoke, rollback validation, provider-outage validation, key-management documentation, and project board closeout.

### 4. Build Artifacts

Expected Linux artifacts:

- `pwned-check_<version>_linux_amd64.tar.gz`
- `pwned-check_<version>_linux_amd64.tar.gz.sha256`
- `pwned-check_<version>_linux_arm64.tar.gz`
- `pwned-check_<version>_linux_arm64.tar.gz.sha256`
- `SHA256SUMS.txt` on published GitHub releases

Build local packages:

```bash
make package-linux
```

Each standalone checker archive contains:

- `pwned-check`
- `install.sh`
- `README.md`
- `LICENSE`
- build and dependency metadata under `metadata/`

Native PAM packaging currently includes Debian/Ubuntu `.deb`, Fedora/RHEL `.rpm`, Arch pacman, and Alpine APK package paths. Release automation builds native PAM packages for `linux/amd64` and `linux/arm64` where the target distro publishes a suitable container builder.

Native PAM package releases must additionally:

- build the native package artifacts for Debian/Ubuntu, Fedora/RHEL, Arch, and Alpine where supported
- build native PAM `linux/amd64` and `linux/arm64` release artifacts where supported; Arch is `linux/amd64` only
- set `SOURCE_DATE_EPOCH` from the release tag timestamp before package builds
- run `make native-pam-release-provenance` after native package artifacts are staged under `dist/release`
- sign `native-pam-SHA256SUMS.txt` and `native-pam-provenance.json` with `PWNED_CHECK_RELEASE_SIGNING_KEY` when release signing keys are available
- sign `.rpm` artifacts with `rpm --addsign` in the release signing environment
- sign or publish `.deb` artifacts through the project Debian repository/release signing process
- attach checksum, provenance, and signature files alongside native PAM packages
- keep private signing keys outside the repository and outside test VMs
- publish production repositories through GitHub Pages under
  `https://phillipmcmahon.github.io/pwned-check/`
- use one maintainer-owned OpenPGP production key for apt/RPM/Arch and one
  maintainer-owned Alpine RSA production key
- record repository signing key fingerprints, rotation due dates, revocation
  notice paths, and operator public-key update steps as described in
  [Package repositories](package-repositories.md#key-rotation-and-revocation)

Signed package repositories are the operator installation channel for native
PAM packages; build and publish them from the validated release package set by
following [Package repositories](package-repositories.md).

The Debian/Ubuntu native package builder runs in a pinned Rust Debian container for both release architectures so the release path does not depend on the host Cargo version.

For every package repository release, complete the repository publication checks in [Package repositories](package-repositories.md):

- publish public key fingerprints and operator trust-bootstrap commands
- generate repository metadata from the validated release package set; use
  `scripts/build-native-pam-apt-repository.sh` for apt and
  `scripts/build-native-pam-rpm-repository.sh` for RPM-family repositories,
  `scripts/build-native-pam-arch-repository.sh` for Arch repositories, and
  `scripts/build-native-pam-alpine-repository.sh` for Alpine repositories
- sign apt, dnf/yum, Arch, and Alpine metadata with keys held outside the repository and outside test VMs
- run repository install smokes on Ubuntu, Debian, Fedora, Rocky, Arch, and Alpine persistent VMs for each published architecture
- confirm the persistent VM fleet is available or record explicit deferrals
  using [VM fleet](vm-fleet.md)
- verify `pwned-check-pam-enable-dry-run`, `pwned-check-pam-enable-enforce`, package rollback, and package removal from each repository install
- record the published repository endpoints, signing key fingerprints, and
  smoke output paths in the release notes before calling the release
  production-ready

The production signing model is defined in [Production release gate](production-release-gate.md#signing-model). Private keys must not be stored in repo-tracked files, persistent distro VMs, smoke fixtures, or package repositories.

Do not publish macOS or Windows artifacts until those roadmap tracks include complete x64 and arm64 build coverage and their signing requirements.

### 5. Publish

- Push the release commit to `main`.
- Monitor the pushed `main` CI run to completion before tagging:
  ```bash
  make github-ci-watch
  ```
  The watcher waits for the CI workflow associated with the pushed `HEAD` SHA
  and exits non-zero if any required CI job fails.
- Create and push the tag.
- Let GitHub Actions build release artifacts.
- Monitor the tag-triggered release workflow from GitHub Actions until it
  reaches a terminal success or failure state. A pushed tag is not considered
  published until the workflow completes successfully and the release assets are
  visible on the GitHub Release.
- Verify artifact checksums.
- Verify release provenance attestation is present for the artifacts listed in
  `SHA256SUMS.txt`.
- For repository-backed releases, verify signed repository metadata and public-key instructions before publishing release notes.
- For repository-backed releases, smoke the live repository endpoints from the
  persistent distro VMs before tagging or promoting release notes:
  ```bash
  make native-pam-live-repo-smokes
  ```
  This runs apt on Ubuntu and Debian, RPM on Fedora and Rocky, Arch on the
  persistent Arch VM, and Alpine on the persistent Alpine arm64 VM.
- Confirm the non-mutating published endpoint monitor passes, or use it for
  focused endpoint diagnosis:
  ```bash
  make native-pam-repo-endpoint-check
  ```
  This is the same check run by the scheduled `Repository Endpoints` GitHub
  Actions workflow. It verifies public keys, signed metadata, indexes, and
  package visibility without installing packages or changing PAM state.
- Archive the release artifacts to the NAS after the GitHub Release assets are
  visible:
  ```bash
  ./scripts/archive-release-to-nas.sh --version v0.1.0
  ```
  This downloads the immutable GitHub Release assets, adds the GitHub source
  archives for the tag, writes them to the configured NAS release root, and
  resets its `latest/<version>/` directory.

  The archive destination is maintainer-local configuration. Set it either with
  environment variables:
  ```bash
  PWNED_CHECK_NAS_HOST=<ssh-host> \
  PWNED_CHECK_NAS_RELEASE_ROOT=<remote-project-root> \
    ./scripts/archive-release-to-nas.sh --version v0.1.0
  ```
  or with a private config file at
  `${XDG_CONFIG_HOME:-$HOME/.config}/pwned-check/archive-release.env`:
  ```bash
  PWNED_CHECK_NAS_HOST=<ssh-host>
  PWNED_CHECK_NAS_RELEASE_ROOT=<remote-project-root>
  PWNED_CHECK_NAS_ARCHIVE_SOURCE=github
  ```
  Keep that config file outside the repository. Co-maintainers should point the
  same script at their own SSH host and project root; the GitHub immutable asset
  mirror behavior is unchanged.
- Confirm release notes include:
  - highlights
  - operator impact
  - validation
  - known limitations

Draft release notes live under `docs/releases/`. Use the matching file as the annotated tag message, for example:

```bash
git tag -a v0.1.0 --cleanup=verbatim -F docs/releases/v0.1.0.md
```

### 6. Close Tracking

- Comment on the release-prep issue with validation and release links.
- For production-ready repository releases, include the completed production gate evidence or the explicit deferment rationale.
- Move shipped story/task issues to `Done`.
- Run the project board audit.
- Run `make github-workflow-status` to confirm the latest completed `main`
  runs for CI, fuzz, and Native PAM Package Gates are green.

## Release Failure Rule

If a release workflow fails after the tag is pushed:

- fix `main` first
- cut a new patch release from the fixed tree
- fold the failed attempt's user-facing notes into the successful release
