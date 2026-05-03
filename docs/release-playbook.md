# Release Playbook

Use this checklist for public releases. The release process is intentionally simple while the project is pre-production.

## Rules

- Release from a clean `main` tree only.
- Validate from the actual release tree.
- Keep release notes operator-focused.
- Do not publish macOS or Windows production artifacts until signing requirements are addressed.
- Keep live HIBP calls out of release validation.

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
- Confirm `pwned-check --version` reports the intended version in the built binary.
- Keep release notes aligned with the actual shipped behavior.

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

Each package contains:

- `pwned-check`
- `pwned-check-pam-helper`
- `install.sh`
- `README.md`
- `LICENSE`
- build and dependency metadata under `metadata/`

Native PAM packaging currently includes Debian/Ubuntu `.deb`, Fedora/RHEL `.rpm`, Arch pacman, and Alpine APK package paths. Release automation builds native PAM packages for `linux/amd64` and `linux/arm64` where the target distro publishes a suitable container builder.

Native PAM package releases must additionally:

- build the native package artifacts for Debian/Ubuntu, Fedora/RHEL, Arch, and Alpine where supported
- build native PAM `linux/amd64` and `linux/arm64` release artifacts; Arch is `linux/amd64` only until an Arch Linux ARM builder image or VM is selected
- set `SOURCE_DATE_EPOCH` from the release tag timestamp before package builds
- run `make native-pam-release-provenance` after native package artifacts are staged under `dist/release`
- sign `native-pam-SHA256SUMS.txt` and `native-pam-provenance.json` with `PWNED_CHECK_RELEASE_SIGNING_KEY` when release signing keys are available
- sign `.rpm` artifacts with `rpm --addsign` in the release signing environment
- sign or publish `.deb` artifacts through the project Debian repository/release signing process
- attach checksum, provenance, and signature files alongside native PAM packages
- keep private signing keys outside the repository and outside test VMs

GitHub Releases are the current native package publication channel. The staged package repository plan lives in [Package repositories](package-repositories.md) and must be followed before publishing apt, dnf/yum, Arch, or Alpine repository metadata.

The Debian/Ubuntu native package builder runs in a pinned Rust Debian container for both release architectures so the release path does not depend on the host Cargo version.

Before the first package repository release, complete the repository-specific signing stories in [Package repositories](package-repositories.md):

- publish public key fingerprints and operator trust-bootstrap commands
- generate repository metadata from the validated release package set
- sign apt, dnf/yum, Arch, and Alpine metadata with keys held outside the repository and outside test VMs
- run repository install smokes on Ubuntu, Debian, Fedora, Alpine, and Arch Docker until an Arch VM exists
- verify `pwned-check-pam-enable-dry-run`, `pwned-check-pam-enable-enforce`, package rollback, and package removal from each repository install

Do not publish macOS or Windows artifacts until those roadmap tracks include complete x64 and arm64 build coverage and their signing requirements.

### 5. Publish

- Push the release commit to `main`.
- Create and push the tag.
- Let GitHub Actions build release artifacts.
- Verify artifact checksums.
- Verify release provenance attestation is present for the published checksums.
- Verify the attestation can be resolved against `SHA256SUMS.txt`.
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
- Move shipped story/task issues to `Done`.
- Run the project board audit.

## Release Failure Rule

If a release workflow fails after the tag is pushed:

- fix `main` first
- cut a new patch release from the fixed tree
- fold the failed attempt's user-facing notes into the successful release
