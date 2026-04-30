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
- `go vet ./...`
- `go run honnef.co/go/tools/cmd/staticcheck ./...`
- binary smoke test result
- Docker smoke matrix result
- CI `lint`, `test`, `smoke`, and `cross-build` jobs
- any manual Linux/PAM validation once available

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

Later packaging may add `.deb` and `.rpm` artifacts after the install model settles.

### 5. Publish

- Push the release commit to `main`.
- Create and push the tag.
- Let GitHub Actions build release artifacts.
- Verify artifact checksums.
- Confirm release notes include:
  - highlights
  - operator impact
  - validation
  - known limitations

### 6. Close Tracking

- Comment on the release-prep issue with validation and release links.
- Move shipped story/task issues to `Done`.
- Run the project board audit.

## Release Failure Rule

If a release workflow fails after the tag is pushed:

- fix `main` first
- cut a new patch release from the fixed tree
- fold the failed attempt's user-facing notes into the successful release
