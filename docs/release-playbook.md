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
| Provider availability | Fail-open and fail-closed provider-availability policy behavior is validated through mocked provider-availability tests. |
| Documentation | `README.md`, [Linux install](linux-install.md), [Package repositories](package-repositories.md), and `CHANGELOG.md` describe the shipped package path accurately. |

Production release notes should reference the
[production baseline SLO](roadmap.md#production-baseline-slo) when describing
repository availability and response posture.

Known architecture deferrals must be named in release notes before a release is
called production-ready. Current Arch support is `x86_64` only.

Private signing keys, passphrases, GitHub credentials, NAS credentials, and VM
passwords must not be stored in the repository, copied to persistent distro
VMs, or embedded in smoke fixtures.

## Tracked Supply-Chain Gaps

These items are explicit follow-ups, not hidden release requirements for the
current package baseline:

| Gap | Current posture | Evidence needed to close | Tracking decision |
|---|---|---|---|
| Reproducible builds | Release artifacts carry checksums, signed provenance, and fixed build timestamps, but independent rebuild equivalence is not yet a release gate. | A documented rebuild procedure that reproduces package payloads from the tagged source and compares normalized package contents across at least one clean maintainer environment. | Track as a future supply-chain hardening follow-up when the release process needs that assurance level. |
| Transparency log | GitHub Releases, signed checksums, signed repository metadata, and endpoint monitoring provide publication evidence, but release metadata is not written to an append-only external transparency log. | A selected log, submission command, inclusion proof capture, and release-note field that records the log entry for each production release. | Track as a future supply-chain hardening follow-up when external transparency becomes a release requirement. |

## 1. Confirm Scope

- Decide which user-visible changes are shipping.
- Update behavior docs and `CHANGELOG.md`.
- Keep a sticky `## Unreleased` placeholder at the top of `CHANGELOG.md`.
- Move every shipped `Unreleased` subsection, including `Known Limitations`,
  into the new versioned changelog section during release prep.
- Confirm no obsolete paths are being preserved without a current design reason.

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

Version mapping:

| Package | Metadata version shape | Verify command |
|---|---|---|
| Debian/Ubuntu `.deb` | `X.Y.Z` | `dpkg-deb -f <file.deb> Version` |
| Fedora/Rocky `.rpm` | `X.Y.Z` with package release in RPM `Release` | `rpm -qp --qf '%{VERSION}-%{RELEASE}\n' <file.rpm>` |
| Arch `.pkg.tar.zst` | `X.Y.Z-1`, where `-1` is `pkgrel` | `zstd -dc <file.pkg.tar.zst> \| tar -xO .PKGINFO \| awk -F' = ' '/^pkgver/ {print $2; exit}'` |
| Alpine `.apk` | `X.Y.Z-r0`, where `-r0` is `pkgrel` | `tar -xzOf <file.apk> .PKGINFO \| awk -F'= ' '/^pkgver/ {print $2; exit}'` |

Incident response should compare the repository index, package metadata,
`pwned-check --version`, release notes, and tag name before declaring a package
version mismatch resolved.

Package releases must:

- set `SOURCE_DATE_EPOCH` from the release tag timestamp
- attach checksums, provenance, signatures, and package files together
- keep signing keys outside the repository, release assets, workflow artifacts,
  caches, logs, GitHub Pages, and test VMs
- publish signed package repositories through GitHub Pages under
  `https://phillipmcmahon.github.io/pwned-check/`
- record repository signing key fingerprints and smoke evidence in release notes

Repository layout, signing, key rotation, and publication commands live in
[Package repositories](package-repositories.md).

Required CI repository-signing secrets:

- `PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY`
- `PWNED_CHECK_CI_OPENPGP_SECRET_KEY`
- `PWNED_CHECK_CI_OPENPGP_FINGERPRINT`
- `PWNED_CHECK_CI_OPENPGP_PASSPHRASE`
- `PWNED_CHECK_CI_ALPINE_PRIVATE_KEY`
- `PWNED_CHECK_CI_ALPINE_PUBLIC_KEY`

Store only the secret values in GitHub Secrets. Do not record secret values,
private key material, or passphrases in the repository, release notes, GitHub
Release assets, Actions artifacts, Pages output, distro VMs, or maintainer
documentation.

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
5. Confirm the release workflow completed these repository publication steps:
   - `Check release assets for private signing material`
   - `Prepare repository signing keys`
   - `Generate signed repositories dry run`
   - `Publish signed repositories to gh-pages`
   - `Validate published repository endpoints`
6. Verify GitHub Release package files, `SHA256SUMS.txt`, provenance
   attestation, and the live package repositories are present.
7. Run live repository smokes from the persistent VMs:
   ```bash
   make native-pam-live-repo-smokes
   ```
8. Run the non-mutating endpoint monitor:
   ```bash
   make native-pam-repo-endpoint-check
   ```
9. If CI repository publication fails after package assets are created,
   diagnose the release workflow first. Use local Docker repository generation
   only as a fallback or recovery path:
   ```bash
   ./scripts/build-native-pam-repositories-docker.sh \
     --version vX.Y.Z \
     --download-release-assets
   ```
10. Archive immutable GitHub Release package files to maintainer-local storage:
    ```bash
    ./scripts/archive-release-to-nas.sh --version vX.Y.Z
    ```
    The destination is private configuration outside the repository.

Release notes should include highlights, operator impact, validation evidence,
GitHub Actions run URLs, validated SHAs, package filenames, checksums, and known
limitations.

Use these release-note headings so the tag-triggered workflow can validate and
publish the signed tag body without the OpenPGP signature block:

```markdown
## Highlights
## Operator impact
## Validation
```

## Failure Rule

If a release workflow fails after a tag is pushed:

- fix `main` first
- cut a new patch release from the fixed tree
- keep release notes focused on the final shipped package behavior
- do not force-update a published release tag unless the release has been
  explicitly withdrawn and the operator impact has been documented
