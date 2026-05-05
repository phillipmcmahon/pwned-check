#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${DOCKER_PAM_SMOKE_PLATFORM:-linux/amd64}"
IMAGES="${DOCKER_PAM_SMOKE_IMAGES:-}"
VERSION="${DOCKER_PAM_SMOKE_VERSION:-pam-smoke}"

usage() {
    cat <<'EOF'
Usage: ./scripts/docker-pam-smoke.sh [OPTIONS]

Build a Linux package and validate package installation plus PAM wiring inside
minimal distro containers.

Options:
  --platform <platform>   Docker platform: linux/amd64 or linux/arm64
  --images "<images>"     Space-separated image list override
  --help                  Show this help text

Environment:
  DOCKER_PAM_SMOKE_PLATFORM  Default Docker platform override (default: linux/amd64)
  DOCKER_PAM_SMOKE_IMAGES    Default image list override
  DOCKER_PAM_SMOKE_WORKDIR   Host staging directory for container artifacts
  DOCKER_PAM_SMOKE_VERSION   Package version label (default: pam-smoke)
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
        DEFAULT_IMAGES="debian:stable-slim ubuntu:24.04 fedora:latest archlinux:base-devel alpine:3.22"
        ;;
    linux/arm64|linux/arm64/v8)
        PLATFORM="linux/arm64"
        GOARCH_VALUE="arm64"
        GOAMD64_VALUE=""
        DEFAULT_IMAGES="debian:stable-slim ubuntu:24.04 fedora:latest rockylinux/rockylinux:10.1 alpine:3.22"
        ;;
    *)
        fail "unsupported platform for PAM smoke: $PLATFORM"
        ;;
esac
[ -n "$IMAGES" ] || IMAGES="$DEFAULT_IMAGES"

cd "$ROOT"

if [ -n "${DOCKER_PAM_SMOKE_WORKDIR:-}" ]; then
    SMOKE_BASE="$DOCKER_PAM_SMOKE_WORKDIR"
elif [ "$(uname -s)" = "Darwin" ]; then
    SMOKE_BASE="/private/tmp"
else
    SMOKE_BASE="/tmp"
fi
SMOKE_DIR="$(mktemp -d "$SMOKE_BASE/pwned-check-docker-pam-smoke.XXXXXX")"
cleanup() {
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT INT TERM

PACKAGE_DIR="$SMOKE_DIR/package"
mkdir -p "$PACKAGE_DIR"
PACKAGE_BASENAME="$(scripts/package-linux-artifact.sh --version "$VERSION" --goarch "$GOARCH_VALUE" --output-dir "$PACKAGE_DIR")"
PACKAGE_PATH="$PACKAGE_DIR/$PACKAGE_BASENAME.tar.gz"

echo "Building PAM package smoke runner for $PLATFORM"
if [ "$GOARCH_VALUE" = "amd64" ]; then
    CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" go build -o "$SMOKE_DIR/pam-package-smoke" ./scripts/pam-package-smoke
else
    CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" go build -o "$SMOKE_DIR/pam-package-smoke" ./scripts/pam-package-smoke
fi

cat > "$SMOKE_DIR/setup-and-run.sh" <<'EOF'
#!/bin/sh
set -eu

install_pam_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates libpam-modules pamtester
    rm -rf /var/lib/apt/lists/*
    return
  fi
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates gcc musl-dev linux-pam linux-pam-dev
    return
  fi
  if command -v pacman >/dev/null 2>&1; then
    if [ -f /etc/pacman.conf ]; then
      sed -i 's/^DownloadUser[[:space:]]*=/#DownloadUser =/' /etc/pacman.conf
    fi
    pacman -Sy --noconfirm --needed ca-certificates gcc glibc pam
    return
  fi
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates gcc pam pam-devel
    dnf clean all
    return
  fi
  echo "unsupported package manager" >&2
  exit 1
}

install_pam_dependencies
/smoke/pam-package-smoke /smoke/package.tar.gz
EOF
chmod 0755 "$SMOKE_DIR/setup-and-run.sh"

for artifact in "$PACKAGE_PATH" "$SMOKE_DIR/pam-package-smoke" "$SMOKE_DIR/setup-and-run.sh"; do
    [ -f "$artifact" ] || fail "missing PAM smoke artifact: $artifact"
done

for image in $IMAGES; do
    echo "Docker PAM smoke: $image ($PLATFORM)"
    cid="$(docker create --platform "$PLATFORM" -w /smoke "$image" /smoke/setup-and-run.sh)"
    docker cp "$PACKAGE_PATH" "$cid:/smoke/package.tar.gz"
    docker cp "$SMOKE_DIR/pam-package-smoke" "$cid:/smoke/pam-package-smoke"
    docker cp "$SMOKE_DIR/setup-and-run.sh" "$cid:/smoke/setup-and-run.sh"
    if ! docker start -a "$cid"; then
        status="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo unknown)"
        docker rm -f "$cid" >/dev/null 2>&1 || true
        fail "Docker PAM smoke failed for $image with exit code $status"
    fi
    docker rm "$cid" >/dev/null
done

echo "Docker PAM smoke matrix passed"
