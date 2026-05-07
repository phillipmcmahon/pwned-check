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

The canonical gate is `scripts/validate-before-push.sh`. At a high level it
runs:

```bash
gofmt -l .
cargo fmt --check
go test -v -race ./...
make native-pam-test
make native-pam-memory-check
make native-pam-build
make native-pam-symbols
make native-pam-deps
make native-pam-harness
make fuzz-smoke
make coverage
go vet ./...
go run honnef.co/go/tools/cmd/staticcheck ./...
make build
make smoke
# persistent VM package smokes for the configured distro hosts
```

Install the matching pre-push hook:

```bash
scripts/install-git-hooks.sh
```

The hook runs the same validation gate before `git push`, including persistent
VM package smoke by default. `scripts/validate-before-push.sh`
syncs the current checkout to every host listed in `PWNED_CHECK_VM_SMOKE_HOSTS`,
copies a locally built static Linux `pwned-check` binary for each VM
architecture, and executes the distro's native PAM smoke over SSH. If a native
package is already installed on a VM, the hook disables and removes that package
first so the full package install, enablement, rollback, removal, and cleanup
smoke runs from a clean package state.

Local amd64 Docker smoke is not part of the default gate because persistent VMs
cover first-wave amd64 distro behavior. Local arm64 Docker smoke is also skipped
by default when matching arm64 VM smoke hosts are configured; use
`PWNED_CHECK_RUN_ARM64_DOCKER=1` only when you deliberately want local
Docker/QEMU CI-parity coverage. Docker release-asset builds remain part of the
GitHub/tagged-release path because GitHub-hosted runners cannot access the
maintainer VM fleet; they are not the local acceptance route when a native VM
exists. Expect optional arm64 Docker stages to take minutes rather than seconds,
especially on emulated hosts or cold package caches. Recent full validation
runs spent roughly 5-10 minutes in the combined arm64 binary and PAM Docker
smoke stages; network and package-manager cache state can move that number
noticeably.
Use `PWNED_CHECK_VM_SMOKE_ONLY=1 ./scripts/validate-before-push.sh` to exercise
just the SSH VM stage. Use `PWNED_CHECK_SKIP_VM_SMOKE=1` or
`PWNED_CHECK_SKIP_ARM64_DOCKER=1` only for deliberate offline work where the
skipped validation will be run separately before pushing.

Standalone Linux tarball packaging is not part of the default validation gate.
The supported Linux application shape is the native distro package path, so
pre-push validates native package build/install behavior instead.

All test-only environment variables must use the `PWNED_CHECK_TEST_*` prefix.
No other prefix is permitted for test scaffolding.

For distro-specific Docker and VM validation, use [Distro testing](distro-testing.md). It defines the supported distro set, Docker coverage, persistent VM setup rules, recovery expectations, and current Ubuntu, Debian, Fedora, Rocky, Alpine, and Arch validation paths.

## Coverage Gate

Product logic packages must meet at least 85% test coverage per package:

```bash
make coverage
```

The coverage gate currently includes:

- `./internal/pwned`

Command entrypoints under `cmd/` and smoke/package harnesses under `scripts/` are intentionally excluded from the coverage threshold. They are thin executable adapters or integration test drivers and are covered through unit tests of their internal packages plus binary, Docker, and PAM package smoke tests.

## Fuzz Schedule

Provider parser fuzzing runs at three depths:

| Scope | Command | Fuzz time | Purpose |
|---|---|---:|---|
| Normal CI and pre-push | `make fuzz-smoke` | `1000 executions` | Fast deterministic regression signal for everyday changes |
| Release validation | `make fuzz-release` | `100000 executions` | Larger deterministic parser robustness check before publishing |
| Scheduled workflow | `make fuzz-nightly` | `1000000 executions` | Deeper recurring search for rare provider parsing bugs |

The fuzz gates use execution counts deliberately. On the current Go toolchain,
wall-clock fuzz runs can stop increasing the executed-input count after the
first few seconds while still waiting for the deadline. Count-based gates state
exactly how many parser invocations were exercised. The scheduled fuzz workflow
runs daily and can also be started manually from GitHub Actions. CI and release
fuzzing must stay independent of the live HIBP API.

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
| `native/pam-pwned-check` | Native PAM module argument parsing, deterministic argv parser corpus coverage, safe conversation strings, PAM constants, service stubs, and checker outcome mapping |
| `scripts/native-pam-harness.sh` | Host-level Linux PAM harness that loads the native module through a temporary PAM service and asserts outcome, conversation, checker argv/stdin/env, timeout cleanup, exec failure, and invalid-argument behavior |
| `scripts/native-pam-ubuntu-deb-package-smoke.sh` | Ubuntu/Debian-family `.deb` smoke that builds the native package, installs it through `dpkg`, exercises installed files, verifies `pwned-check-pam-enable-dry-run`, `pwned-check-pam-enable-enforce`, `pwned-check-pam-disable`, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-apt-repo-smoke.sh` | Debian/Ubuntu apt repository smoke that installs from signed repository metadata and a public key only, then exercises dry-run/enforce/disable, package purge, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-ubuntu-hardening-assessment.sh` | Ubuntu/Debian-family hardening assessment that wraps the `.deb` package smoke, captures AppArmor state, and proves a deliberately broken disposable PAM service can be restored |
| `scripts/native-pam-memory-check.sh` | Linux Valgrind memory-check path for the native PAM Rust argv parser tests |
| `scripts/native-pam-fedora-rpm-package-smoke.sh` | Fedora/RHEL-family RPM smoke that builds the native RPM, installs it through package tooling, exercises installed files, verifies authselect dry-run/enforce switching and rollback, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-rpm-repo-smoke.sh` | Fedora/Rocky RPM repository smoke that installs from signed RPMs and signed repository metadata with a public key only, then exercises dry-run/enforce/disable, package removal, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-fedora-selinux-assessment.sh` | Fedora/RHEL-family SELinux assessment that wraps the RPM package smoke, captures SELinux/authselect/audit state, and fails on pwned-check-related AVCs |
| `scripts/native-pam-distro-smoke.sh` | Throwaway first-wave distro containers that build `pam_pwned_check.so`, install it into the distro PAM module directory, and exercise direct native PAM allow/reject behavior |
| `scripts/native-pam-service-installed-smoke.sh` | Reusable installed-file smoke for Arch/Alpine service-file wrapper packages that exercises dry-run/enforce switching, clean/reject behavior, and rollback through installed package wrappers |
| `scripts/native-pam-container-package-smoke.sh --distro arch` | Arch Docker CI/fallback smoke that builds the `PKGBUILD` package, installs it with `pacman`, exercises installed service-file wrapper behavior, removes the package, and checks managed-file cleanup. Local Arch validation uses `codex-vm-arch` through `scripts/validate-before-push.sh` |
| `scripts/native-pam-arch-repo-smoke.sh` | Arch repository smoke that installs from signed package files and signed pacman database metadata with a locally trusted public key, then exercises dry-run/enforce/disable, package removal, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-container-package-smoke.sh --distro alpine` | Alpine Docker smoke that builds the `APKBUILD` package, installs it with `apk`, exercises installed service-file wrapper behavior, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-alpine-repo-smoke.sh` | Alpine repository smoke that installs from a signed APK index and public RSA key without `--allow-untrusted`, then exercises dry-run/enforce/disable, package removal, managed-file cleanup, and writes a combined `.test-output/` report |
| `scripts/native-pam-live-repo-smokes.sh` | Release-gate wrapper for published repository endpoints. Runs apt, RPM, Arch, and Alpine smokes on persistent VMs where architecture coverage exists |
| `scripts/native-pam-repo-endpoint-check.sh` | Non-mutating published endpoint monitor for scheduled CI. Verifies public keys, signed apt/RPM/Arch metadata, Alpine signed index presence, and package visibility without installing packages |
| `scripts/smoke_binary.go` | Built-binary behavior against a mocked range service |
| `scripts/container-smoke` | In-container Linux binary behavior across distro images |

## CI Rules

CI should not depend on the live HIBP API. Automated tests use mocked HIBP-compatible range responses.

The GitHub workflow is split into:

- `lint`: gofmt check and `go vet`
- `staticcheck`: standalone Staticcheck job, intended to be configured as a required branch-protection check
- `test`: race-enabled Go tests, bounded parser fuzz smoke, and 85% per-package coverage threshold
- `native-pam`: Rust format check, native PAM unit tests, Valgrind-backed native PAM memory check, Linux `pam_pwned_check.so` build, exported PAM symbol check, dynamic dependency allowlist check, and host-level native PAM harness
- `smoke`: built-binary smoke and Docker distro smoke for `linux/amd64` and `linux/arm64`
- `release`: tagged release publishing with the deterministic release parser fuzz gate before package publication, including native PAM package files for the supported repository architectures
- `fuzz`: scheduled and manual deterministic parser fuzz workflow

The `Native PAM Package Gates` workflow runs weekly and on demand for heavier package validation. It covers the Ubuntu `.deb` package smoke, direct native PAM Docker matrix, Arch package smoke, Alpine Docker fallback package smoke, and an arm64 native PAM package smoke for Debian, Fedora, and Alpine package outputs. Debian `.deb` validation, Fedora RPM/SELinux validation, Alpine package validation, and Arch package validation remain documented release gates on persistent VMs because they depend on real package-manager, PAM, or security-module state. Arch package automation is `linux/amd64` only.

The `Repository Endpoints` workflow runs daily and on demand. It does not
install packages or alter PAM state. It validates that the published GitHub
Pages repository endpoints expose the expected public keys, signed metadata,
repository indexes, and `pwned-check-native-pam` package entries. It is an
availability and publication-drift monitor, not a replacement for the
persistent VM release gate in `make native-pam-live-repo-smokes`.

Run `make github-workflow-status` during release closeout to confirm the latest
completed `main` runs for CI, fuzz, Native PAM Package Gates, and Repository
Endpoints are green. This catches scheduled workflow failures that local
validation and tag-triggered release checks do not see automatically.

During release publication, run `make github-ci-watch` immediately after
pushing the release commit to `main`. That command waits for the GitHub CI run
for the pushed `HEAD` SHA and streams it to completion with
`gh run watch --exit-status`; a successful `git push` is not release evidence by
itself.

Current smoke architecture coverage:

| Area | Local Pre-Push | GitHub CI |
|---|---|---|
| CLI binary smoke | Host-built binary on the development machine | Host-built binary on `ubuntu-24.04` |
| Docker binary smoke, `linux/amd64` | Not run by default, because local amd64 acceptance is VM-backed; available manually for CI reproduction | Debian, Ubuntu, Fedora, Arch, Alpine |
| Docker binary smoke, `linux/arm64` | Optional with `PWNED_CHECK_RUN_ARM64_DOCKER=1` because local arm64 acceptance is VM-backed where matching guests exist | Debian, Ubuntu, Fedora, Rocky, Alpine |
| Native PAM package smoke, `linux/amd64` | Ubuntu, Debian, Fedora, Rocky, Alpine, and Arch on persistent VMs | Ubuntu `.deb` runner smoke; Docker native PAM package gates for Arch and Alpine |
| Native PAM package smoke, `linux/arm64` | Ubuntu, Debian, Fedora, Rocky, and Alpine on persistent VMs | Docker native PAM package gates for Debian, Fedora, and Alpine arm64 package outputs |
| Native PAM packages, `linux/amd64` | Built and accepted on persistent VMs for each supported package family | Built during tagged release package preparation in Docker containers |
| Native PAM packages, `linux/arm64` | Built and accepted on persistent VMs for each supported package family except Arch ARM, which is not targeted | Native PAM package gates smoke Debian, Fedora, and Alpine arm64 package outputs; tagged release builds arm64 packages in Docker containers |
| Live repository endpoint smoke | `make native-pam-live-repo-smokes` on persistent VMs, including Alpine arm64, before repository-backed release promotion | Not run in normal CI because it mutates real package-manager state and depends on maintainer VMs |
| Live repository endpoint monitor | `make native-pam-repo-endpoint-check` for local endpoint diagnosis | Scheduled and manual `Repository Endpoints` workflow validates published metadata/signatures without package install |
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
- bounded parser fuzz coverage, including the release execution-count gate
- 85% minimum coverage for included product logic packages
- binary smoke test
- Docker binary smoke matrix across Debian, Ubuntu, Fedora, Arch Linux, and Alpine on `linux/amd64`, plus Debian, Ubuntu, Fedora, Rocky, and Alpine on `linux/arm64`
- Rocky/RHEL-compatible host validation on the persistent Rocky VM
- native distro package builds for supported `amd64`/`x86_64` and `arm64`/`aarch64` repository architectures, with release checksums

CI intentionally produces only Linux `amd64` and `arm64` packages while Linux remains the active integration target. macOS and Windows packages should be introduced together, with both x64 and arm64 coverage, when those roadmap tracks include their signing requirements.

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
- package wrappers enable dry-run, switch to enforcement, disable, remove packages, and restore PAM state
- exact safe conversation strings and syslog events are emitted without plaintext candidate leakage
- distro package placement and shared-library dependencies match the supported distro family

## Static Analysis

Staticcheck is pinned through Go module metadata and runs in both local validation and CI:

```bash
go run honnef.co/go/tools/cmd/staticcheck ./...
```
