# Testing Guide

The test suite should mirror the current architecture:

```text
CLI -> config -> hash split -> provider -> exit code
```

## Local Validation

Run the default validation gate:

```bash
make validate
```

Equivalent commands:

```bash
gofmt -l .
cargo fmt --check
go test ./...
make native-pam-test
make native-pam-memory-check
make native-pam-build
make native-pam-symbols
make native-pam-deps
make native-pam-harness
make native-pam-ubuntu-host-package-smoke
make native-pam-ubuntu-deb-package-smoke
make native-pam-ubuntu-hardening-assessment
make native-pam-distro-smoke
make native-pam-generic-package-smoke
make native-pam-arch-package-smoke
make native-pam-alpine-package-smoke
make package-native-pam-debian
make package-native-pam-rpm
make package-native-pam-generic
make package-native-pam-arch
make package-native-pam-alpine
make fuzz-smoke
make coverage
go vet ./...
go run honnef.co/go/tools/cmd/staticcheck ./...
go build -o dist/pwned-check ./cmd/pwned-check
go run ./scripts/smoke_binary.go dist/pwned-check
./scripts/validate-before-push.sh
make package-linux
```

Install the matching pre-push hook:

```bash
scripts/install-git-hooks.sh
```

The hook runs the same validation gate before `git push`, including persistent
VM package smoke and arm64 Docker smoke by default. `scripts/validate-before-push.sh`
syncs the current checkout to every host listed in `PWNED_CHECK_VM_SMOKE_HOSTS`,
copies a locally built static Linux `pwned-check` binary for package smokes, and
executes the distro's native PAM smoke over SSH. If a native package is already
installed on a VM, the hook disables and removes that package first so the full
package install, enablement, rollback, removal, and cleanup smoke runs from a
clean package state. Local amd64 Docker smoke is not part of the default gate
because the persistent VMs cover first-wave amd64 distro behavior; local arm64
Docker smoke runs for Debian, Ubuntu, Fedora, Rocky, and Alpine to reduce the gap with
GitHub CI.
Expect the local arm64 Docker stage to take minutes rather than seconds,
especially on emulated hosts or cold package caches. Recent full validation
runs have spent roughly 5-10 minutes in the combined arm64 binary and PAM
Docker smoke stages; network and package-manager cache state can move that
number noticeably.
Use `PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh` to exercise
just the SSH VM stage. Use `PWNED_CHECK_SKIP_VM_SMOKE=1` or
`PWNED_CHECK_SKIP_ARM64_DOCKER=1` only for deliberate offline work where the
skipped validation will be run separately before pushing.

For native PAM development, run the persistent Ubuntu smoke container:

```bash
make native-pam-ubuntu-smoke
```

The first run builds a reusable Ubuntu 24.04 image with Rust and PAM development headers, creates a persistent container named `pwned-check-native-pam-dev`, syncs the current checkout into it, builds `pam_pwned_check.so`, installs it into Ubuntu's PAM security module directory, and exercises `pam_chauthtok` through a generated PAM service. Use `./scripts/native-pam-ubuntu-smoke.sh shell` to inspect the container between runs, or `./scripts/native-pam-ubuntu-smoke.sh clean` to remove it.

Each run copies the container test log, per-case PAM output, captured syslog, and selected `/tmp/native-pam-smoke-*` artifacts into an ignored timestamped directory such as `.test-output/native-pam-ubuntu-smoke/20260501T063620Z-native-pam-ubuntu-smoke`. These run directories sort chronologically by name, and `.test-output/native-pam-ubuntu-smoke/latest` points at the newest run. Each run also writes a combined `<timestamp>-native-pam-ubuntu-smoke.txt` file for quick double-click or Preview inspection. Set `NATIVE_PAM_UBUNTU_OUTPUT_DIR` to write those artifacts somewhere else.

For distro-specific Docker and VM validation, use the runbook in [distro-testing.md](distro-testing.md). It defines the first-wave distro set, Docker matrices, persistent VM setup rules, and the current Ubuntu, Debian, Fedora, Alpine, Arch, and Docker coverage paths.

## Coverage Gate

Product logic packages must meet at least 85% test coverage per package:

```bash
make coverage
```

The coverage gate currently includes:

- `./internal/pwned`
- `./internal/pamhelper`

Command entrypoints under `cmd/` and smoke/package harnesses under `scripts/` are intentionally excluded from the coverage threshold. They are thin executable adapters or integration test drivers and are covered through unit tests of their internal packages plus binary, Docker, and PAM package smoke tests.

## Fuzz Schedule

Provider parser fuzzing runs at three depths:

| Scope | Command | Fuzz time | Purpose |
|---|---|---:|---|
| Normal CI and pre-push | `make fuzz-smoke` | `5s` | Fast regression signal for everyday changes |
| Release validation | `make fuzz-release` | `60s` | Longer parser robustness check before publishing |
| Scheduled workflow | `make fuzz-nightly` | `5m` | Deeper recurring search for rare provider parsing bugs |

The scheduled fuzz workflow runs daily and can also be started manually from GitHub Actions. CI and release fuzzing must stay independent of the live HIBP API.

Native PAM argv parsing has a deterministic property-style corpus in the Rust unit tests. The corpus combines supported arguments, malformed key/value pairs, active `min_count` input, large numeric values, whitespace, empty values, and conflicting policy flags. `make native-pam-test` runs that corpus on every native PAM test pass.

`make native-pam-memory-check` builds the native PAM Rust test binary and runs the argv parser tests under Valgrind when Valgrind is available. The target skips cleanly on non-Linux hosts and hosts without Valgrind, and CI installs Valgrind for the native PAM job.

## Test Layout

| Area | Focus |
|---|---|
| `internal/pwned/core_test.go` | Hash splitting and provider-agnostic validation |
| `internal/pwned/config_test.go` | Environment configuration defaults and overrides |
| `internal/pwned/provider_test.go` | HIBP-compatible range response parsing and privacy headers |
| `internal/pwned/provider_fuzz_test.go` | Parser fuzz coverage for HIBP-compatible range responses |
| `internal/pwned/cli_test.go` | CLI exit codes, fail-open/fail-closed, logging, and mocked provider flow |
| `internal/pamhelper/helper_test.go` | PAM helper exit mapping, timeout, and no-secret-output behavior |
| `native/pam-pwned-check` | Native PAM module argument parsing, deterministic argv parser corpus coverage, safe conversation strings, PAM constants, service stubs, and checker outcome mapping |
| `scripts/native-pam-harness.sh` | Host-level Linux PAM harness that loads the native module through a temporary PAM service and asserts outcome, conversation, checker argv/stdin/env, timeout cleanup, exec failure, and invalid-argument behavior |
| `scripts/native-pam-ubuntu-host-package-smoke.sh` | Ubuntu host package-layout smoke that installs the Debian/Ubuntu artifact, exercises the installed module through a disposable PAM service, and rolls back host files without enabling `pam-auth-update` |
| `scripts/native-pam-ubuntu-deb-package-smoke.sh` | Ubuntu/Debian-family `.deb` smoke that builds the native package, installs it through `dpkg`, exercises installed files, verifies `pwned-check-pam-enable-dry-run`, `pwned-check-pam-enable-enforce`, `pwned-check-pam-disable`, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-apt-repo-smoke.sh` | Debian/Ubuntu apt repository smoke that installs from signed repository metadata and a public key only, then exercises dry-run/enforce/disable, package purge, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-ubuntu-hardening-assessment.sh` | Ubuntu/Debian-family hardening assessment that wraps the `.deb` package smoke, captures AppArmor state, and proves a deliberately broken disposable PAM service can be restored |
| `scripts/native-pam-memory-check.sh` | Linux Valgrind memory-check path for the native PAM Rust argv parser tests |
| `scripts/native-pam-fedora-host-package-smoke.sh` | Fedora/RHEL-family host package-layout smoke that installs the RPM-family artifact, exercises the installed module through a disposable PAM service, verifies authselect dry-run/enforce switching, and rolls back host files and authselect state |
| `scripts/native-pam-fedora-rpm-package-smoke.sh` | Fedora/RHEL-family RPM smoke that builds the native RPM, installs it through package tooling, exercises installed files, verifies authselect dry-run/enforce switching and rollback, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-rpm-repo-smoke.sh` | Fedora/Rocky RPM repository smoke that installs from signed RPMs and signed repository metadata with a public key only, then exercises dry-run/enforce/disable, package removal, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-fedora-selinux-assessment.sh` | Fedora/RHEL-family SELinux assessment that wraps the host package smoke, captures SELinux/authselect/audit state, and fails on pwned-check-related AVCs |
| `scripts/native-pam-ubuntu-smoke.sh` | Persistent Ubuntu native PAM module build, install, exported-symbol, dependency, Debian/Ubuntu package-layout artifact, and `pam_chauthtok` smoke path |
| `scripts/native-pam-distro-smoke.sh` | Throwaway first-wave distro containers that build `pam_pwned_check.so`, install it into the distro PAM module directory, and exercise direct native PAM allow/reject behavior |
| `scripts/native-pam-generic-package-smoke.sh` | Generic manual-PAM artifact install, helper-driven dry-run/enforce switching, real `pam_chauthtok` allow/reject behavior, and rollback on Arch and Alpine |
| `scripts/native-pam-manual-installed-smoke.sh` | Reusable installed-file smoke for manual-PAM packages that exercises dry-run/enforce switching, clean/reject behavior, and rollback through installed manual helpers |
| `scripts/native-pam-arch-package-smoke.sh` | Arch Docker CI/fallback smoke that builds the `PKGBUILD` package, installs it with `pacman`, exercises installed manual-PAM behavior, removes the package, and checks managed-file cleanup. Local Arch validation uses `codex-vm-arch` through `scripts/validate-before-push.sh` |
| `scripts/native-pam-arch-repo-smoke.sh` | Arch repository smoke that installs from signed package files and signed pacman database metadata with a locally trusted public key, then exercises dry-run/enforce/disable, package removal, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-alpine-package-smoke.sh` | Alpine Docker smoke that builds the `APKBUILD` package, installs it with `apk`, exercises installed manual-PAM behavior, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-alpine-repo-smoke.sh` | Alpine repository smoke that installs from a signed APK index and public RSA key without `--allow-untrusted`, then exercises dry-run/enforce/disable, package removal, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-live-repo-smokes.sh` | Release-gate wrapper for published repository endpoints. Runs apt, RPM, and Arch smokes on persistent VMs where architecture coverage exists, and records Alpine as deferred unless a matching Alpine host is configured |
| `scripts/smoke_binary.go` | Built-binary behavior against a mocked range service |
| `scripts/container-smoke` | In-container Linux binary behavior across distro images |
| `scripts/pam-package-smoke` | In-container package install, `/etc/pam.d` wiring, and PAM allow/reject outcomes through `pam_exec.so expose_authtok` |

## CI Rules

CI should not depend on the live HIBP API. Automated tests use mocked HIBP-compatible range responses.

The GitHub workflow is split into:

- `lint`: gofmt check and `go vet`
- `staticcheck`: standalone Staticcheck job, intended to be configured as a required branch-protection check
- `test`: race-enabled Go tests, bounded parser fuzz smoke, and 85% per-package coverage threshold
- `native-pam`: Rust format check, native PAM unit tests, Valgrind-backed native PAM memory check, Linux `pam_pwned_check.so` build, exported PAM symbol check, dynamic dependency allowlist check, and host-level native PAM harness
- `smoke`: built-binary smoke, Docker distro smoke for `linux/amd64` and `linux/arm64`, and Docker PAM package smoke against mocked HIBP-compatible endpoints
- `package-linux`: Linux release package builds for `amd64` and `arm64`
- `release`: tagged release publishing with 60s parser fuzz before artifact publication, including native PAM package assets for `linux/amd64` and `linux/arm64` where a supported distro builder image exists

The `Native PAM Package Gates` workflow runs weekly and on demand for heavier package validation. It covers the Ubuntu `.deb` package smoke, direct native PAM Docker matrix, generic manual-PAM package Docker matrix, Arch package smoke, Alpine Docker fallback package smoke, and an arm64 native PAM release-asset smoke for Debian, Fedora, and Alpine package outputs. Debian `.deb` host validation, Fedora RPM/SELinux host validation, Alpine package validation, and Arch package validation remain documented release gates on persistent VMs because they depend on real host package, PAM, or security-module state. Arch package automation remains `linux/amd64` until the project chooses an Arch Linux ARM builder image or VM.

Run `make github-workflow-status` during release closeout to confirm the latest
completed `main` runs for CI, fuzz, and Native PAM Package Gates are green.
This catches scheduled workflow failures that local validation and
tag-triggered release checks do not see automatically.
- `fuzz`: scheduled and manual 5m parser fuzz workflow

During release publication, run `make github-ci-watch` immediately after
pushing the release commit to `main`. That command waits for the GitHub CI run
for the pushed `HEAD` SHA and streams it to completion with
`gh run watch --exit-status`; a successful `git push` is not release evidence by
itself.

Current smoke architecture coverage:

| Area | Local Pre-Push | GitHub CI |
|---|---|---|
| CLI binary smoke | Host-built binary on the development machine | Host-built binary on `ubuntu-24.04` |
| Docker binary smoke, `linux/amd64` | Not run by default, because first-wave local amd64 coverage is VM-backed; available manually for CI reproduction | Debian, Ubuntu, Fedora, Arch, Alpine |
| Docker binary smoke, `linux/arm64` | Run by full `scripts/validate-before-push.sh` for Debian, Ubuntu, Fedora, Rocky, and Alpine | Debian, Ubuntu, Fedora, Rocky, Alpine |
| Docker PAM package smoke, `linux/amd64` | Not run by default, because first-wave local amd64 coverage is VM-backed; available manually for CI reproduction | Debian, Ubuntu, Fedora, Arch, Alpine |
| Docker PAM package smoke, `linux/arm64` | Run by full `scripts/validate-before-push.sh` for Debian, Ubuntu, Fedora, Rocky, and Alpine | Debian, Ubuntu, Fedora, Rocky, Alpine |
| Native PAM package smoke, `linux/amd64` | Ubuntu, Debian, Fedora, Rocky, Alpine, and Arch on persistent VMs | Ubuntu `.deb` runner smoke; Docker native PAM package gates for Arch and Alpine |
| Native PAM release assets, `linux/amd64` | Built by `make package-native-pam-*` as needed | Built during tagged release asset preparation |
| Native PAM release assets, `linux/arm64` | Built manually through `scripts/build-native-pam-release-assets.sh --platform linux/arm64` | Native PAM package gates smoke Debian, Fedora, and Alpine arm64 package outputs; tagged release builds arm64 assets |
| Live repository endpoint smoke | `make native-pam-live-repo-smokes` on persistent VMs before repository-backed release promotion | Not run in normal CI because it mutates real package-manager state and depends on maintainer VMs |
| Arch package path | `codex-vm-arch` over SSH, `linux/amd64` | Docker `linux/amd64` only |

Release-sensitive checks:

- CLI exit-code behavior
- no plaintext password in output
- stable safe log event shape
- exact safe conversation strings for the native PAM module
- exported PAM service symbols on `pam_pwned_check.so`
- native PAM module dynamic dependency allowlist
- mocked HIBP-compatible provider contract
- provider timeout/failure behavior
- fail-open/fail-closed provider outage behavior
- bounded parser fuzz coverage, including a 60s release gate
- 85% minimum coverage for included product logic packages
- binary smoke test
- Docker binary smoke matrix across Debian, Ubuntu, Fedora, Arch Linux, and Alpine on `linux/amd64`, plus Debian, Ubuntu, Fedora, Rocky, and Alpine on `linux/arm64`
- Docker PAM package smoke across Debian, Ubuntu, Fedora, Arch Linux, and Alpine on `linux/amd64`, plus Debian, Ubuntu, Fedora, Rocky, and Alpine on `linux/arm64`
- Rocky/RHEL-compatible host validation on the persistent Rocky VM
- Linux package build for `amd64` and `arm64` with SHA256 files

CI intentionally produces only Linux `amd64` and `arm64` distributable artifacts while Linux remains the active integration target. macOS and Windows artifacts should be reintroduced together, with both x64 and arm64 coverage, when those roadmap tracks include their signing requirements.

The repository currently has no branch protection enabled. Once branch protection or rulesets are enabled for `main`, require the `Staticcheck` job alongside the existing test and packaging checks.

## Additional Linters Under Consideration

`golangci-lint` would let the project add `gosec`, `errcheck`, `revive`, and related checks behind one runner. Do not enable it casually: introduce it with a checked-in configuration, review findings for signal, and document any suppressions so the gate does not become noisy coverage theater.

## Linux Integration Testing

Use this guide for the validation gate and test ownership map. Use
[Distro testing runbook](distro-testing.md) for the detailed Linux distro
process, including when local validation must use persistent VMs instead of
Docker.

The native PAM Linux integration suite proves:

- `pam_pwned_check.so` builds, exports the expected symbols, and loads through Linux PAM
- the module can obtain the candidate from existing `PAM_AUTHTOK` or through `pam_get_authtok`
- clean, pwned, fail-open, fail-closed, timeout, config-error, and unexpected-exit outcomes map correctly
- package helpers enable dry-run, switch to enforcement, disable, remove packages, and restore PAM state
- exact safe conversation strings and syslog events are emitted without plaintext candidate leakage
- distro package placement and shared-library dependencies match the supported distro family

The PAM package smoke path proves:

- known pwned password is rejected
- clean password is accepted
- provider failure follows fail-open/fail-closed configuration
- child process timeout blocks hangs
- package installation creates stable binary and symlink paths
- a dedicated `/etc/pam.d/pwned-check-smoke` service can pass the candidate token to the helper

The automated PAM smoke uses an isolated PAM `auth` service to drive token exposure deterministically in containers. When `pamtester` is unavailable, the runner compiles a tiny fallback PAM client and now prints the selected client, distro identity, and generated PAM service before executing cases. This is intentionally verbose enough to make any future helper-path segfault actionable. Operator-facing password-change placement is documented in [Operations](operations.md) and should be tested on the target host before enablement.

## Static Analysis

Staticcheck is pinned through Go module metadata and runs in both local validation and CI:

```bash
go run honnef.co/go/tools/cmd/staticcheck ./...
```
