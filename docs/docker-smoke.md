# Docker Smoke Matrix

The Docker smoke matrix validates that the Linux binaries run on a range of minimal distro images.

The smoke test builds static Linux binaries for:

- `pwned-check`
- `pwned-check-pam-helper`
- `container-smoke`, the test runner used inside the container

Artifacts are staged under `/private/tmp` on macOS and `/tmp` elsewhere, then copied into each container with `docker cp`. This avoids Docker Desktop file-sharing issues when the repository lives in a protected or space-containing path such as `Documents/New project`. Override the staging base with `DOCKER_SMOKE_WORKDIR` if your Docker host requires a different path.

The container runner then checks:

- both binaries report a version
- `pwned-check --stdin` rejects a mocked pwned password through the HIBP provider path
- `pwned-check --stdin` follows fail-open and fail-closed outage policy without calling the live HIBP API
- `pwned-check-pam-helper` allows a clean fail-open provider outage
- `pwned-check-pam-helper` rejects a mocked pwned password
- `pwned-check-pam-helper` rejects fail-closed provider outage as a checker provider failure
- `pwned-check-pam-helper` rejects checker timeout
- neither checker nor helper logs the plaintext password in the tested paths

## Default Matrix

The default matrix is:

| Distro | Image |
|---|---|
| Debian | `debian:stable-slim` |
| Ubuntu | `ubuntu:24.04` |
| Fedora | `fedora:latest` |
| Arch Linux | `archlinux:base-devel` |
| Alpine | `alpine:3.20` |

The Debian, Ubuntu, and Alpine entries use explicit stable tags. Arch Linux and Fedora do not provide a long-lived fixed release tag that is as useful for this smoke purpose, so they intentionally track their rolling/latest public base images. Rocky Linux coverage runs on `codex-vm-rocky`; do not use the `rockylinux` Docker image for local Rocky validation.

## Run Locally

```bash
make docker-smoke
```

Equivalent command:

```bash
./scripts/docker-smoke.sh
```

## Platform Selection

By default, the script uses `linux/amd64`. This matches CI and keeps the full distro matrix available, including Arch Linux. On Apple Silicon Docker Desktop, this may use amd64 emulation.

Force a platform:

```bash
./scripts/docker-smoke.sh --platform linux/amd64
./scripts/docker-smoke.sh --platform linux/arm64
```

The script supports:

- `linux/amd64`
- `linux/arm64`

## Image Override

Use `--images` for a one-off matrix:

```bash
./scripts/docker-smoke.sh --images "debian:stable-slim alpine:3.20"
```

For local VM-first validation, run Docker only for targets without persistent
VMs:

```bash
./scripts/docker-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
```

Or use the environment variable:

```bash
  DOCKER_SMOKE_IMAGES="ubuntu:24.04 fedora:latest" ./scripts/docker-smoke.sh
```

Override the staging directory:

```bash
DOCKER_SMOKE_WORKDIR=/tmp ./scripts/docker-smoke.sh
```

## CI Behavior

GitHub Actions runs:

```bash
./scripts/docker-smoke.sh --platform linux/amd64
```

This keeps CI aligned with the canonical Linux release architecture. Local arm64 validation is still available with `--platform linux/arm64`, but the full default matrix may not be available because `archlinux:base-devel` does not currently publish an arm64 image.

## Stability Rules

- Keep the default image list small and representative.
- Prefer explicit stable tags where the distro publishes them.
- Do not add package-manager installation inside the containers unless a test genuinely needs it.
- Keep the binaries static with `CGO_ENABLED=0` so the smoke checks test distro runtime compatibility rather than distro toolchain setup.
- If an image tag changes, update this document and the script in the same commit.

# Docker PAM Package Smoke Matrix

The PAM package smoke matrix validates the Linux process-integration path rather than only binary execution.

The smoke test builds an amd64 Linux release package, copies it into each distro container, installs the package with its bundled `install.sh`, writes a dedicated `/etc/pam.d/pwned-check-smoke` service, then drives that service through the distro-packaged `pamtester` client where available. Alpine, Arch Linux, and Rocky Linux do not package `pamtester` for the pinned/default image tags, so the runner compiles a tiny PAM client inside those throwaway containers.

The runner prints the selected PAM client, `/etc/os-release` `PRETTY_NAME`, and generated PAM service before executing cases. Keep that context in bug reports, especially for rolling images such as Fedora and Arch where PAM or libc behavior can change between runs.

The generated PAM service is intentionally isolated from the distro's real password-change files. It uses PAM's `auth` module type so the smoke client can supply a candidate token consistently across minimal containers while still exercising `pam_exec.so expose_authtok` and helper exit-code mapping through the real PAM module boundary:

```text
auth requisite pam_exec.so expose_authtok quiet /usr/local/bin/pwned-check-pam-helper --checker /usr/local/bin/pwned-check-smoke-checker --timeout 3s
auth required pam_permit.so
```

This confirms:

- the release package installs `pwned-check` and `pwned-check-pam-helper`
- install symlinks are created under `/usr/local/lib/pwned-check`
- `/etc/pam.d` can load `pam_exec.so` and pass the candidate token with `expose_authtok`
- the helper calls the installed checker through a fixed executable path
- PAM allows or rejects the flow according to the helper exit code

## PAM Test Cases

The PAM smoke runner validates these combinations:

| Candidate | Provider | Fail mode | Expected PAM result |
|---|---|---|---|
| clean | available | fail-open | allow |
| clean | available | fail-closed | allow |
| pwned | available | fail-open | reject |
| pwned | available | fail-closed | reject |
| clean | unavailable | fail-open | allow |
| pwned | unavailable | fail-open | allow |
| clean | unavailable | fail-closed | reject |
| pwned | unavailable | fail-closed | reject |
| empty | available | fail-open | reject |
| clean | checker timeout | fail-open | reject |
| clean | invalid checker config | fail-open | reject |

The available-provider cases use an in-container mocked HIBP range service. The unavailable-provider cases point the checker at `127.0.0.1:9` so the result is deterministic and does not depend on the public HIBP API.

## Run PAM Smoke Locally

```bash
make docker-pam-smoke
```

Equivalent command:

```bash
./scripts/docker-pam-smoke.sh --platform linux/amd64
```

For local VM-first validation, limit the Docker PAM package smoke to targets
without persistent VMs:

```bash
./scripts/docker-pam-smoke.sh --platform linux/amd64 --images "archlinux:base-devel"
```

The default distro list matches the binary Docker smoke matrix:

```text
debian:stable-slim ubuntu:24.04 fedora:latest archlinux:base-devel alpine:3.20
```

Use a smaller matrix while iterating:

```bash
./scripts/docker-pam-smoke.sh --images "debian:stable-slim alpine:3.20"
```

The PAM smoke installs PAM runtime support and either `pamtester` or the minimal packages needed to compile the fallback PAM client inside each throwaway container. That makes it slower than `make docker-smoke`, but it keeps the test reproducible against minimal public distro images without requiring custom fixture images.

## Native PAM Distro Smoke

The native PAM module has a separate first-wave distro smoke that builds and loads `pam_pwned_check.so` directly:

```bash
make native-pam-distro-smoke
```

Equivalent command:

```bash
./scripts/native-pam-distro-smoke.sh --platform linux/amd64
```

Use a smaller native matrix while iterating:

```bash
./scripts/native-pam-distro-smoke.sh --images "fedora:latest archlinux:base-devel"
```

For the full distro testing workflow, including persistent Ubuntu, Debian, Fedora, Rocky, and Alpine VMs, see [distro-testing.md](distro-testing.md).
