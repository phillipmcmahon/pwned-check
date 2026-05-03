#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME=""
SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-}"
PLATFORM="${NATIVE_PAM_RELEASE_PLATFORM:-linux/amd64}"

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-release-assets.sh --version <version> [OPTIONS]

Build native Linux PAM package artifacts for release publication. Debian/Ubuntu
is built on the current Linux host. Fedora/RPM, Arch, and Alpine package paths
are built in distro containers and copied into the output directory.

Options:
  --version <version>       Release version, for example 0.1.2
  --output-dir <dir>        Output directory (default: dist/release)
  --build-time <timestamp>  RFC3339 build timestamp
  --source-date-epoch <n>   SOURCE_DATE_EPOCH for package builds
  --platform <platform>     Docker platform (default: linux/amd64)
  --help                    Show this help text
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
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --build-time)
            [ "$#" -ge 2 ] || fail "--build-time requires a value"
            BUILD_TIME="$2"
            shift 2
            ;;
        --source-date-epoch)
            [ "$#" -ge 2 ] || fail "--source-date-epoch requires a value"
            SOURCE_EPOCH="$2"
            shift 2
            ;;
        --platform)
            [ "$#" -ge 2 ] || fail "--platform requires a value"
            PLATFORM="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

[ -n "$VERSION" ] || fail "--version is required"

case "$PLATFORM" in
    linux/amd64) ;;
    *) fail "unsupported native PAM release platform: $PLATFORM" ;;
esac

require_command docker
require_command go

if [ "$(uname -s)" != "Linux" ]; then
    fail "Debian/Ubuntu native PAM package build requires a Linux host"
fi

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
if [ -z "$SOURCE_EPOCH" ]; then
    SOURCE_EPOCH="$(date -u -d "$BUILD_TIME" '+%s' 2>/dev/null || date -u '+%s')"
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(CDPATH= cd -- "$OUTPUT_DIR" && pwd)"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-release.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

PREBUILT_CHECKER="$WORK_DIR/pwned-check"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64="${GOAMD64:-v1}" \
    go build -trimpath \
    -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION -X github.com/phillipmcmahon/pwned-check/internal/pamhelper.Version=$VERSION" \
    -o "$PREBUILT_CHECKER" "$ROOT/cmd/pwned-check"

sync_repo_to_container() {
    cid="$1"
    dest="$2"
    docker exec "$cid" sh -lc "rm -rf '$dest' && mkdir -p '$dest'"
    tar \
        --exclude=.git \
        --exclude=.test-output \
        --exclude=build \
        --exclude=dist \
        --exclude=target \
        -C "$ROOT" \
        -cf - . \
        | docker exec -i "$cid" tar -C "$dest" -xf -
}

echo "Building Debian/Ubuntu native PAM package"
SOURCE_DATE_EPOCH="$SOURCE_EPOCH" "$ROOT/scripts/package-native-pam-debian-package.sh" \
    --version "$VERSION" \
    --output-dir "$OUTPUT_DIR" \
    --build-time "$BUILD_TIME" \
    --pwned-check-bin "$PREBUILT_CHECKER"

echo "Building Fedora/RPM native PAM package"
FEDORA_CID="$(docker create --platform "$PLATFORM" fedora:latest sleep infinity)"
cleanup_fedora() {
    docker rm -f "$FEDORA_CID" >/dev/null 2>&1 || true
}
trap 'cleanup_fedora; cleanup' EXIT INT TERM
docker start "$FEDORA_CID" >/dev/null
sync_repo_to_container "$FEDORA_CID" /workspace/pwned-check
docker cp "$PREBUILT_CHECKER" "$FEDORA_CID:/tmp/pwned-check-release"
docker exec "$FEDORA_CID" sh -lc "
    set -eu
    dnf install -y ca-certificates cargo file gcc gcc-c++ make pam-devel pkgconf-pkg-config rpm-build rust tar gzip xz findutils diffutils
    cd /workspace/pwned-check
    rm -rf dist/release
    mkdir -p dist/release
    SOURCE_DATE_EPOCH='$SOURCE_EPOCH' ./scripts/package-native-pam-rpm-package.sh \
      --version '$VERSION' \
      --build-time '$BUILD_TIME' \
      --pwned-check-bin /tmp/pwned-check-release
"
docker cp "$FEDORA_CID:/workspace/pwned-check/dist/release/." "$OUTPUT_DIR/"
cleanup_fedora
trap cleanup EXIT INT TERM

echo "Building and smoking Arch native PAM package"
NATIVE_PAM_ARCH_PACKAGE_SMOKE_VERSION="$VERSION" \
NATIVE_PAM_ARCH_PACKAGE_SMOKE_EXPORT_DIR="$OUTPUT_DIR" \
    "$ROOT/scripts/native-pam-arch-package-smoke.sh" --platform "$PLATFORM"

echo "Building and smoking Alpine native PAM package"
NATIVE_PAM_ALPINE_PACKAGE_SMOKE_VERSION="$VERSION" \
NATIVE_PAM_ALPINE_PACKAGE_SMOKE_EXPORT_DIR="$OUTPUT_DIR" \
    "$ROOT/scripts/native-pam-alpine-package-smoke.sh" --platform "$PLATFORM"

PWNED_CHECK_RELEASE_ARTIFACT_DIR="$OUTPUT_DIR" \
PWNED_CHECK_RELEASE_PROVENANCE_DIR="$OUTPUT_DIR" \
SOURCE_DATE_EPOCH="$SOURCE_EPOCH" \
    "$ROOT/scripts/native-pam-release-provenance.sh"

echo "Native PAM release assets built in $OUTPUT_DIR"
