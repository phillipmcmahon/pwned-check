# Docker Smoke Matrix

The Docker smoke matrix validates that the Linux binaries run on a range of minimal distro images.

The smoke test builds static Linux binaries for:

- `pwned-check`
- `pwned-check-pam-helper`
- `container-smoke`, the test runner used inside the container

Artifacts are staged under `/private/tmp` on macOS and `/tmp` elsewhere, then copied into each container with `docker cp`. This avoids Docker Desktop file-sharing issues when the repository lives in a protected or space-containing path such as `Documents/New project`. Override the staging base with `DOCKER_SMOKE_WORKDIR` if your Docker host requires a different path.

The container runner then checks:

- both binaries report a version
- `pwned-check --stdin` rejects a mocked pwned password
- `pwned-check-pam-helper` allows a clean fail-open result
- `pwned-check-pam-helper` rejects a mocked pwned password
- `pwned-check-pam-helper` rejects checker timeout
- neither checker nor helper logs the plaintext password in the tested paths

## Default Matrix

The default matrix is:

| Distro | Image |
|---|---|
| Debian | `debian:stable-slim` |
| Ubuntu | `ubuntu:24.04` |
| Alpine | `alpine:3.20` |
| Arch Linux | `archlinux:base-devel` |
| Fedora | `fedora:latest` |

The Debian, Ubuntu, and Alpine entries use explicit stable tags. Arch Linux and Fedora do not provide a long-lived fixed release tag that is as useful for this smoke purpose, so they intentionally track their rolling/latest public base images.

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
