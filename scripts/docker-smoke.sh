#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${DOCKER_SMOKE_PLATFORM:-linux/amd64}"
GOOS_VALUE="linux"
GOARCH_VALUE="${GOARCH:-}"
IMAGES="${DOCKER_SMOKE_IMAGES:-debian:stable-slim ubuntu:24.04 alpine:3.20 archlinux:base-devel fedora:latest}"

usage() {
    cat <<'EOF'
Usage: ./scripts/docker-smoke.sh [OPTIONS]

Build static Linux smoke artifacts and run them inside a minimal distro matrix.

Options:
  --platform <platform>   Docker platform, for example linux/amd64 or linux/arm64
  --images "<images>"     Space-separated image list override
  --help                  Show this help text

Environment:
  DOCKER_SMOKE_PLATFORM   Default Docker platform override (default: linux/amd64)
  DOCKER_SMOKE_IMAGES     Default image list override
  DOCKER_SMOKE_WORKDIR    Host staging directory for container-mounted artifacts
  GOARCH                  Go target arch override when --platform is not used
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --platform)
            [ "$#" -ge 2 ] || fail "--platform requires a value"
            PLATFORM="$2"
            shift 2
            ;;
        --images)
            [ "$#" -ge 2 ] || fail "--images requires a value"
            IMAGES="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

require_command docker
require_command go

case "$PLATFORM" in
    linux/amd64)
        GOARCH_VALUE="amd64"
        GOAMD64_VALUE="${GOAMD64:-v1}"
        ;;
    linux/arm64|linux/arm64/v8)
        GOARCH_VALUE="arm64"
        GOAMD64_VALUE=""
        ;;
    *)
        fail "unsupported platform: $PLATFORM"
        ;;
esac

cd "$ROOT"

if [ -n "${DOCKER_SMOKE_WORKDIR:-}" ]; then
    SMOKE_BASE="$DOCKER_SMOKE_WORKDIR"
elif [ "$(uname -s)" = "Darwin" ]; then
    SMOKE_BASE="/private/tmp"
else
    SMOKE_BASE="/tmp"
fi
SMOKE_DIR="$(mktemp -d "$SMOKE_BASE/pwned-check-docker-smoke.XXXXXX")"
cleanup() {
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT INT TERM

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo dev)"
LDFLAGS="-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION"

echo "Building Linux smoke artifacts for $PLATFORM"
CGO_ENABLED=0 GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" go build -ldflags "$LDFLAGS" -o "$SMOKE_DIR/pwned-check" ./cmd/pwned-check
CGO_ENABLED=0 GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" go build -o "$SMOKE_DIR/pwned-check-pam-helper" ./cmd/pwned-check-pam-helper
CGO_ENABLED=0 GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" go build -o "$SMOKE_DIR/container-smoke" ./scripts/container-smoke

for artifact in pwned-check pwned-check-pam-helper container-smoke; do
    [ -x "$SMOKE_DIR/$artifact" ] || fail "missing smoke artifact: $SMOKE_DIR/$artifact"
done

for image in $IMAGES; do
    echo "Docker smoke: $image ($PLATFORM)"
    cid="$(docker create --platform "$PLATFORM" -w /smoke "$image" /smoke/container-smoke /smoke/pwned-check /smoke/pwned-check-pam-helper)"
    docker cp "$SMOKE_DIR/." "$cid:/smoke"
    if ! docker start -a "$cid"; then
        status="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo unknown)"
        docker rm -f "$cid" >/dev/null 2>&1 || true
        fail "Docker smoke failed for $image with exit code $status"
    fi
    docker rm "$cid" >/dev/null
done

echo "Docker smoke matrix passed"
