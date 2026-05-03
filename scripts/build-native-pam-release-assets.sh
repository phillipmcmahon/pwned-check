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
require_command dpkg-deb
require_command rpm
require_command tar
require_command zstd

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
CLEANUP_HANDLERS=""

register_cleanup() {
    CLEANUP_HANDLERS="$1${CLEANUP_HANDLERS:+ $CLEANUP_HANDLERS}"
}

run_cleanups() {
    status=$?
    trap - EXIT INT TERM
    for handler in $CLEANUP_HANDLERS; do
        "$handler"
    done
    exit "$status"
}

cleanup_work_dir() {
    rm -rf "$WORK_DIR"
}

register_cleanup cleanup_work_dir
trap run_cleanups EXIT INT TERM

PREBUILT_CHECKER="$WORK_DIR/pwned-check"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64="${GOAMD64:-v1}" \
    go build -trimpath \
    -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION -X github.com/phillipmcmahon/pwned-check/internal/pamhelper.Version=$VERSION" \
    -o "$PREBUILT_CHECKER" "$ROOT/cmd/pwned-check"

verify_version() {
    file="$1"
    expected="$2"
    actual=""

    case "$file" in
        *.deb)
            actual="$(dpkg-deb -f "$file" Version)"
            ;;
        *.rpm)
            actual="$(rpm -qp --qf '%{VERSION}' "$file" 2>/dev/null)"
            ;;
        *.apk)
            expected="${expected}-r0"
            actual="$(tar -xzOf "$file" .PKGINFO | awk -F' *= *' '/^pkgver/ {print $2; exit}')"
            ;;
        *.pkg.tar.zst)
            expected="${expected}-1"
            actual="$(zstd -dc "$file" | tar -xO .PKGINFO | awk -F' *= *' '/^pkgver/ {print $2; exit}')"
            ;;
        *)
            echo "unsupported package artifact for version verification: $file" >&2
            return 1
            ;;
    esac

    if [ "$actual" != "$expected" ]; then
        echo "version mismatch: $file has $actual, expected $expected" >&2
        return 1
    fi

    return 0
}

verify_package_versions() {
    found=0
    failures=0
    for file in \
        "$OUTPUT_DIR"/*.deb \
        "$OUTPUT_DIR"/*.rpm \
        "$OUTPUT_DIR"/*.apk \
        "$OUTPUT_DIR"/*.pkg.tar.zst
    do
        [ -e "$file" ] || continue
        if ! verify_version "$file" "$VERSION"; then
            failures=$((failures + 1))
        fi
        found=$((found + 1))
    done

    [ "$found" -gt 0 ] || fail "no native package artifacts found for version verification"
    [ "$failures" -eq 0 ] || fail "$failures package artifact(s) failed version verification"
    echo "Verified native package metadata versions for $found artifacts"
}

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

echo "::group::[build:debian] packaging"
# TODO(arm64): build Debian/Ubuntu artifacts in a pinned Debian container when
# the native PAM release matrix grows beyond linux/amd64.
SOURCE_DATE_EPOCH="$SOURCE_EPOCH" "$ROOT/scripts/package-native-pam-debian-package.sh" \
    --version "$VERSION" \
    --output-dir "$OUTPUT_DIR" \
    --build-time "$BUILD_TIME" \
    --pwned-check-bin "$PREBUILT_CHECKER"
echo "::endgroup::"

echo "::group::[build:rpm] packaging"
FEDORA_CID="$(docker create --platform "$PLATFORM" fedora:latest sleep infinity)"
cleanup_fedora() {
    [ -n "${FEDORA_CID:-}" ] || return 0
    docker rm -f "$FEDORA_CID" >/dev/null 2>&1 || true
    FEDORA_CID=""
}
register_cleanup cleanup_fedora
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
echo "::endgroup::"

echo "::group::[build+smoke:arch] package smoke"
NATIVE_PAM_ARCH_PACKAGE_SMOKE_VERSION="$VERSION" \
NATIVE_PAM_ARCH_PACKAGE_SMOKE_EXPORT_DIR="$OUTPUT_DIR" \
    "$ROOT/scripts/native-pam-arch-package-smoke.sh" --platform "$PLATFORM"
echo "::endgroup::"

echo "::group::[build+smoke:alpine] package smoke"
NATIVE_PAM_ALPINE_PACKAGE_SMOKE_VERSION="$VERSION" \
NATIVE_PAM_ALPINE_PACKAGE_SMOKE_EXPORT_DIR="$OUTPUT_DIR" \
    "$ROOT/scripts/native-pam-alpine-package-smoke.sh" --platform "$PLATFORM"
echo "::endgroup::"

echo "::group::[verify] package metadata versions"
verify_package_versions
echo "::endgroup::"

PWNED_CHECK_RELEASE_ARTIFACT_DIR="$OUTPUT_DIR" \
PWNED_CHECK_RELEASE_PROVENANCE_DIR="$OUTPUT_DIR" \
SOURCE_DATE_EPOCH="$SOURCE_EPOCH" \
    "$ROOT/scripts/native-pam-release-provenance.sh"

echo "Native PAM release assets built in $OUTPUT_DIR"
