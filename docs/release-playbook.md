# Release Playbook

Use this checklist for public releases. Release from a clean `main` tree,
validate the exact tree being tagged, and keep release notes operator-focused.

## Release Gate

A native Linux package release can be called production-ready only when these
items are complete and recorded in the release notes:

| Area | Required evidence |
|---|---|
| Signing | Apt, RPM, Arch, and Alpine repository metadata is signed; package signatures exist where the package manager expects them; checksum and provenance files are signed when release signing keys are available. |
| Repository publication | Repositories are generated from the validated release package set and published without replacing payloads at an existing version. |
| Repository smoke | Installs use only public repository configuration, public keys, and normal package-manager commands. Target VMs do not need GitHub credentials, build tools, a checkout, or private signing keys. |
| Rollback | Each repository smoke covers dry-run enablement, enforcement, disable, package removal, and PAM/authselect rollback. |
| Provider outage | Fail-open and fail-closed behavior is validated through mocked provider-outage tests. |
| Documentation | `README.md`, [Linux install](linux-install.md), [Package repositories](package-repositories.md), and `CHANGELOG.md` describe the shipped package path accurately. |

Known architecture deferrals must be named in release notes before a release is
called production-ready. Current Arch support is `x86_64` only.

Private signing keys, passphrases, GitHub credentials, NAS credentials, and VM
passwords must not be stored in the repository, copied to persistent distro
VMs, or embedded in smoke fixtures.

## 1. Confirm Scope

- Decide which user-visible changes are shipping.
- Update behavior docs and `CHANGELOG.md`.
- Keep a sticky `## Unreleased` placeholder at the top of `CHANGELOG.md`.
- Confirm no legacy or migration-only paths are being preserved without a
  current design reason.

## 2. Prepare Version

Update version metadata:

```bash
make prepare-release-version VERSION=vX.Y.Z
```

This updates `native/pam-pwned-check/Cargo.toml`, refreshes `Cargo.lock`, and
verifies the Rust crate version matches the tag without the leading `v`.

Then confirm:

- `pwned-check --version` reports the intended version in a built binary
- release notes match the actual shipped behavior
- validation entries are written in past tense after checks complete

## 3. Validate

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
- binary smoke result
- Docker smoke matrix result
- CI `lint`, `staticcheck`, `test`, and `smoke` jobs
- native PAM package, VM, and repository smoke results when shipping package changes
- GitHub Actions run URLs and the commit SHA each run validated

Run `make github-ci-watch` immediately after pushing the release commit to
`main`. A successful `git push` is not release evidence by itself.

## 4. Build Package Artifacts

Native Linux package releases build:

- Debian/Ubuntu `.deb`: `amd64`, `arm64`
- Fedora/RHEL/Rocky `.rpm`: `x86_64`, `aarch64`
- Arch package: `x86_64`
- Alpine `.apk`: `x86_64`, `aarch64`
- native PAM checksums, build metadata, and provenance

Local build commands:

```bash
make package-native-pam-debian
make package-native-pam-rpm
make package-native-pam-arch
make package-native-pam-alpine
make native-pam-release-provenance
```

Tagged release automation builds the same package families through
`scripts/build-native-pam-release-assets.sh`.

Package releases must:

- set `SOURCE_DATE_EPOCH` from the release tag timestamp
- attach checksums, provenance, signatures, and package files together
- keep signing keys outside the repository and outside test VMs
- publish signed package repositories through GitHub Pages under
  `https://phillipmcmahon.github.io/pwned-check/`
- record repository signing key fingerprints and smoke evidence in release notes

Repository layout, signing, key rotation, and publication commands live in
[Package repositories](package-repositories.md).

## 5. Publish

1. Push the release commit to `main`.
2. Monitor the pushed `main` CI run:
   ```bash
   make github-ci-watch
   ```
3. Create and push a signed tag:
   ```bash
   git tag -s -u <release-signing-key-id> vX.Y.Z --cleanup=verbatim -F <release-notes-file>
   git push origin vX.Y.Z
   ```
   Prefer `gpg-agent` with loopback pinentry enabled for non-interactive
   signing. A maintainer-local passphrase file may unlock the agent, but it is
   not a repository input.
4. Monitor the tag-triggered release workflow to terminal success.
5. Verify GitHub Release package files, `SHA256SUMS.txt`, and provenance
   attestation are present.
6. Publish signed package repositories from the immutable GitHub Release
   package files.
7. Wait for GitHub Pages deployment.
8. Run live repository smokes:
   ```bash
   make native-pam-live-repo-smokes
   ```
9. Run the non-mutating endpoint monitor:
   ```bash
   make native-pam-repo-endpoint-check
   ```
10. Archive immutable GitHub Release package files to maintainer-local storage:
    ```bash
    ./scripts/archive-release-to-nas.sh --version vX.Y.Z
    ```
    The destination is private configuration outside the repository.

Release notes should include highlights, operator impact, validation evidence,
GitHub Actions run URLs, validated SHAs, package filenames, checksums, and known
limitations.

## Failure Rule

If a release workflow fails after a tag is pushed:

- fix `main` first
- cut a new patch release from the fixed tree
- fold the failed attempt's user-facing notes into the successful release
- do not force-update a published release tag unless the release has been
  explicitly withdrawn and the operator impact has been documented
