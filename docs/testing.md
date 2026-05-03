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
./scripts/docker-smoke.sh --platform linux/amd64 --images "rockylinux:9 archlinux:base-devel"
./scripts/docker-pam-smoke.sh --platform linux/amd64 --images "rockylinux:9 archlinux:base-devel"
make package-linux
```

Install the matching pre-push hook:

```bash
scripts/install-git-hooks.sh
```

The hook runs the same validation gate before `git push`.

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
| `scripts/native-pam-ubuntu-hardening-assessment.sh` | Ubuntu/Debian-family hardening assessment that wraps the `.deb` package smoke, captures AppArmor state, and proves a deliberately broken disposable PAM service can be restored |
| `scripts/native-pam-memory-check.sh` | Linux Valgrind memory-check path for the native PAM Rust argv parser tests |
| `scripts/native-pam-fedora-host-package-smoke.sh` | Fedora/RHEL-family host package-layout smoke that installs the RPM-family artifact, exercises the installed module through a disposable PAM service, verifies authselect dry-run/enforce switching, and rolls back host files and authselect state |
| `scripts/native-pam-fedora-rpm-package-smoke.sh` | Fedora/RHEL-family RPM smoke that builds the native RPM, installs it through package tooling, exercises installed files, verifies authselect dry-run/enforce switching and rollback, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-fedora-selinux-assessment.sh` | Fedora/RHEL-family SELinux assessment that wraps the host package smoke, captures SELinux/authselect/audit state, and fails on pwned-check-related AVCs |
| `scripts/native-pam-ubuntu-smoke.sh` | Persistent Ubuntu native PAM module build, install, exported-symbol, dependency, Debian/Ubuntu package-layout artifact, and `pam_chauthtok` smoke path |
| `scripts/native-pam-distro-smoke.sh` | Throwaway first-wave distro containers that build `pam_pwned_check.so`, install it into the distro PAM module directory, and exercise direct native PAM allow/reject behavior |
| `scripts/native-pam-generic-package-smoke.sh` | Generic manual-PAM artifact install, helper-driven dry-run/enforce switching, real `pam_chauthtok` allow/reject behavior, and rollback on Arch and Alpine |
| `scripts/native-pam-manual-installed-smoke.sh` | Reusable installed-file smoke for manual-PAM packages that exercises dry-run/enforce switching, clean/reject behavior, and rollback through installed manual helpers |
| `scripts/native-pam-arch-package-smoke.sh` | Arch Docker smoke that builds the `PKGBUILD` package, installs it with `pacman`, exercises installed manual-PAM behavior, removes the package, and checks managed-file cleanup |
| `scripts/native-pam-alpine-package-smoke.sh` | Alpine Docker smoke that builds the `APKBUILD` package, installs it with `apk`, exercises installed manual-PAM behavior, removes the package, and checks managed-file cleanup |
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
- `smoke`: built-binary smoke, Docker distro smoke, and Docker PAM package smoke against mocked HIBP-compatible endpoints
- `package-linux`: Linux release package builds for `amd64` and `arm64`
- `release`: tagged release publishing with 60s parser fuzz before artifact publication, including native PAM package assets for `linux/amd64` and `linux/arm64` where a supported distro builder image exists

The `Native PAM Package Gates` workflow runs weekly and on demand for heavier package validation. It covers the Ubuntu `.deb` package smoke, direct native PAM Docker matrix, generic manual-PAM package Docker matrix, Arch package smoke, and Alpine Docker fallback package smoke. Debian `.deb` host validation, Fedora RPM/SELinux host validation, and Alpine package validation remain documented release gates on persistent VMs because they depend on real host package, PAM, or security-module state. Arch package automation remains `linux/amd64` until the project chooses an Arch Linux ARM builder image or persistent VM.
- `fuzz`: scheduled and manual 5m parser fuzz workflow

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
- Docker smoke matrix across Debian, Ubuntu, Fedora, Rocky or another RHEL-compatible image, Arch Linux, and Alpine
- Docker PAM package smoke across Debian, Ubuntu, Fedora, Rocky or another RHEL-compatible image, Arch Linux, and Alpine
- Linux package build for `amd64` and `arm64` with SHA256 files

CI intentionally produces only Linux `amd64` and `arm64` distributable artifacts while Linux remains the active integration target. macOS and Windows artifacts should be reintroduced together, with both x64 and arm64 coverage, when those roadmap tracks include their signing requirements.

The repository currently has no branch protection enabled. Once branch protection or rulesets are enabled for `main`, require the `Staticcheck` job alongside the existing test and packaging checks.

## Additional Linters Under Consideration

`golangci-lint` would let the project add `gosec`, `errcheck`, `revive`, and related checks behind one runner. Do not enable it casually: introduce it with a checked-in configuration, review findings for signal, and document any suppressions so the gate does not become noisy coverage theater.

## Linux Integration Testing

The native PAM Ubuntu smoke path proves the in-development module can be built on Ubuntu, installed where Linux PAM expects security modules, loaded by a real PAM stack, and exercised through `pam_chauthtok`. It uses a test-only PAM module to seed `PAM_AUTHTOK` before `pam_pwned_check.so` for existing-token cases, and also covers the self-sufficient `pam_get_authtok` path when no earlier module has populated the token. It then runs a fake checker to cover clean, pwned, provider fail-open, provider fail-closed, checker config, checker timeout, dry-run, `min_count` forwarding, invalid module argument, exported-symbol, and dependency-allowlist behavior without calling the live HIBP API. The smoke also installs the generated Debian/Ubuntu native PAM artifact, enables its `pam-auth-update` profile, verifies the generated `common-password` line, disables the profile, and restores the container PAM state for repeatable rollback testing. The smoke asserts the checker receives `--stdin` plus `--min-count <n>` only when configured, receives the candidate over stdin, receives the expected fail-closed environment without ambient caller variables, is not invoked for invalid module arguments, emits the exact approved PAM conversation messages, emits the expected syslog events through `/dev/log`, does not echo candidate tokens into PAM output or logs, and does not leave the timeout checker process alive.

The host-level native PAM harness is the CI-oriented counterpart to the persistent smoke. It builds the module on the current Linux runner, compiles a tiny token-seeding PAM module and PAM client, creates a temporary service under `/etc/pam.d`, and loads `pam_pwned_check.so` by absolute path. It covers the same core allow/reject matrix plus checker exec failure and unexpected checker exit, while avoiding persistent Docker state.

The Debian VM path validates the Debian/Ubuntu package behavior on a real Debian host. It runs native PAM unit/build/dependency/symbol gates, the host-level PAM harness, the Debian/Ubuntu host package-layout smoke, and the native `.deb` package smoke. On Debian 13, run package smoke commands with `PATH="/usr/sbin:$PATH"` because `pam-auth-update` is installed in `/usr/sbin` and may not be visible in a non-root SSH session. The 2026-05-03 Debian VM gate passed after the checker runner began mapping path-qualified missing or non-executable checkers to deterministic `ExecFailure` before `fork/exec`.

The native PAM distro smoke matrix is the portability counterpart. It uses throwaway containers for the first-wave distro set, installs each distro's Rust and Linux-PAM development packages, builds `pam_pwned_check.so` in that environment, installs it into the distro PAM module directory, and runs direct `pam_chauthtok` allow/reject cases. Use `NATIVE_PAM_DISTRO_SMOKE_IMAGES` or `--images` to run a smaller subset while iterating.

The full distro testing process, including when to prefer Docker versus persistent VMs, is documented in [distro-testing.md](distro-testing.md).

The PAM package smoke path proves:

- known pwned password is rejected
- clean password is accepted
- provider failure follows fail-open/fail-closed configuration
- child process timeout blocks hangs
- package installation creates stable binary and symlink paths
- a dedicated `/etc/pam.d/pwned-check-smoke` service can pass the candidate token to the helper

The automated PAM smoke uses an isolated PAM `auth` service to drive token exposure deterministically in containers. When `pamtester` is unavailable, the runner compiles a tiny fallback PAM client and now prints the selected client, distro identity, and generated PAM service before executing cases. This is intentionally verbose enough to make any future helper-path segfault actionable. The operator-facing password-change placement remains the Linux PAM PoC path and should be manually tested before enabling it on a host.

## Static Analysis

Staticcheck is pinned through Go module metadata and runs in both local validation and CI:

```bash
go run honnef.co/go/tools/cmd/staticcheck ./...
```
