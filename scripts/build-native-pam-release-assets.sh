#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME=""
SOURCE_EPOCH="${SOURCE_DATE_EPOCH:-}"
PLATFORM="${NATIVE_PAM_RELEASE_PLATFORM:-linux/amd64}"
GOARCH_VALUE=""

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-release-assets.sh --version <version> [OPTIONS]

Build native Linux PAM package artifacts for GitHub/tagged release publication.
Debian/Ubuntu, Fedora/RPM, Arch, and Alpine package paths are built in distro
containers because GitHub-hosted release runners cannot access the maintainer
VM fleet. Local package acceptance still uses persistent VMs when a matching VM
exists. Arch package release builds currently require linux/amd64 because the
official archlinux:base-devel image is amd64-only.

Options:
  --version <version>       Release version, for example 1.0.0
  --output-dir <dir>        Output directory (default: dist/release)
  --build-time <timestamp>  RFC3339 build timestamp
  --source-date-epoch <n>   SOURCE_DATE_EPOCH for package builds
  --platform <platform>     Docker platform: linux/amd64 or linux/arm64
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
    linux/amd64)
        GOARCH_VALUE="amd64"
        ;;
    linux/arm64|linux/arm64/v8)
        PLATFORM="linux/arm64"
        GOARCH_VALUE="arm64"
        ;;
    *) fail "unsupported native PAM release platform: $PLATFORM" ;;
esac

require_command docker
require_command go
require_command tar
require_command zstd

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
if [ "$GOARCH_VALUE" = "amd64" ]; then
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64="${GOAMD64:-v1}" \
        go build -trimpath \
        -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION" \
        -o "$PREBUILT_CHECKER" "$ROOT/cmd/pwned-check"
else
    CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" \
        go build -trimpath \
        -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION" \
        -o "$PREBUILT_CHECKER" "$ROOT/cmd/pwned-check"
fi

verify_version() {
    file="$1"
    expected="$2"
    actual=""

    case "$file" in
        *.deb)
            if command -v dpkg-deb >/dev/null 2>&1; then
                actual="$(dpkg-deb -f "$file" Version)"
            else
                actual="$(query_artifact_in_container debian:stable-slim "$file" dpkg-deb -f /tmp/native-pam-artifact Version)"
            fi
            ;;
        *.rpm)
            if command -v rpm >/dev/null 2>&1; then
                actual="$(rpm -qp --qf '%{VERSION}' "$file" 2>/dev/null)"
            else
                actual="$(query_artifact_in_container fedora:latest "$file" rpm -qp --qf '%{VERSION}' /tmp/native-pam-artifact 2>/dev/null)"
            fi
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

require_artifact() {
    pattern="$1"
    set -- "$OUTPUT_DIR"/$pattern
    [ -e "$1" ] || fail "required release artifact missing for $PLATFORM: $pattern"
    [ "$#" -eq 1 ] || fail "required release artifact pattern is ambiguous for $PLATFORM: $pattern"
}

verify_platform_artifacts() {
    case "$PLATFORM" in
        linux/amd64)
            require_artifact "pwned-check-native-pam_${VERSION}_amd64.deb"
            require_artifact "pwned-check-native-pam-${VERSION}-*.x86_64.rpm"
            require_artifact "pwned-check-native-pam-${VERSION}-*-x86_64.pkg.tar.zst"
            require_artifact "pwned-check-native-pam-${VERSION}-r0-x86_64.apk"
            ;;
        linux/arm64)
            require_artifact "pwned-check-native-pam_${VERSION}_arm64.deb"
            require_artifact "pwned-check-native-pam-${VERSION}-*.aarch64.rpm"
            require_artifact "pwned-check-native-pam-${VERSION}-r0-aarch64.apk"
            # Arch Linux ARM is not published from the official Arch package path.
            ;;
        *)
            fail "unsupported platform artifact verification target: $PLATFORM"
            ;;
    esac

    echo "Verified required release artifacts for $PLATFORM"
}

sync_repo_to_container() {
    cid="$1"
    dest="$2"
    docker exec "$cid" sh -lc "rm -rf '$dest' && mkdir -p '$dest'"
    if [ "$(uname -s)" = "Darwin" ]; then
        TAR_XATTR_FLAGS="--no-xattrs"
    elif tar --help 2>/dev/null | grep -q -- '--no-xattrs'; then
        TAR_XATTR_FLAGS="--no-xattrs"
    else
        TAR_XATTR_FLAGS=""
    fi
    COPYFILE_DISABLE=1 tar $TAR_XATTR_FLAGS \
        --exclude=.git \
        --exclude=.test-output \
        --exclude=build \
        --exclude=dist \
        --exclude=target \
        -C "$ROOT" \
        -cf - . \
        | docker exec -i "$cid" tar -C "$dest" -xf -
}

query_artifact_in_container() {
    image="$1"
    artifact="$2"
    shift 2
    cid="$(docker create "$image" sleep infinity)"
    docker start "$cid" >/dev/null
    docker cp "$artifact" "$cid:/tmp/native-pam-artifact"
    set +e
    docker exec "$cid" "$@"
    status=$?
    set -e
    docker rm -f "$cid" >/dev/null 2>&1 || true
    return "$status"
}

echo "::group::[build:debian:$PLATFORM] packaging"
DEBIAN_CID="$(docker create --platform "$PLATFORM" rust:1-bookworm sleep infinity)"
cleanup_debian() {
    [ -n "${DEBIAN_CID:-}" ] || return 0
    docker rm -f "$DEBIAN_CID" >/dev/null 2>&1 || true
    DEBIAN_CID=""
}
register_cleanup cleanup_debian
docker start "$DEBIAN_CID" >/dev/null
sync_repo_to_container "$DEBIAN_CID" /workspace/pwned-check
docker cp "$PREBUILT_CHECKER" "$DEBIAN_CID:/tmp/pwned-check-release"
docker exec "$DEBIAN_CID" sh -lc "
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends build-essential ca-certificates curl dpkg-dev libpam0g-dev libpam-runtime make pkg-config tar
    rm -rf /var/lib/apt/lists/*
    curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable
    . /usr/local/cargo/env
    cd /workspace/pwned-check
    rm -rf dist/release
    mkdir -p dist/release
    SOURCE_DATE_EPOCH='$SOURCE_EPOCH' ./scripts/package-native-pam-debian-package.sh \
      --version '$VERSION' \
      --build-time '$BUILD_TIME' \
      --pwned-check-bin /tmp/pwned-check-release
"
docker cp "$DEBIAN_CID:/workspace/pwned-check/dist/release/." "$OUTPUT_DIR/"
cleanup_debian
echo "::endgroup::"

echo "::group::[build:rpm:$PLATFORM] packaging"
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

case "$PLATFORM" in
    linux/amd64)
        echo "::group::[build+smoke:arch:$PLATFORM] package smoke"
        NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_VERSION="$VERSION" \
        NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_EXPORT_DIR="$OUTPUT_DIR" \
            "$ROOT/scripts/native-pam-container-package-smoke.sh" --distro arch --platform "$PLATFORM"
        echo "::endgroup::"
        ;;
    *)
        echo "::notice::Skipping Arch native PAM package for $PLATFORM; archlinux:base-devel does not publish this platform"
        ;;
esac

echo "::group::[build+smoke:alpine:$PLATFORM] package smoke"
NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_VERSION="$VERSION" \
NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_EXPORT_DIR="$OUTPUT_DIR" \
    "$ROOT/scripts/native-pam-container-package-smoke.sh" --distro alpine --platform "$PLATFORM"
echo "::endgroup::"

echo "::group::[verify] package metadata versions"
verify_package_versions
verify_platform_artifacts
echo "::endgroup::"

PWNED_CHECK_RELEASE_ARTIFACT_DIR="$OUTPUT_DIR" \
PWNED_CHECK_RELEASE_PROVENANCE_DIR="$OUTPUT_DIR" \
SOURCE_DATE_EPOCH="$SOURCE_EPOCH" \
    "$ROOT/scripts/native-pam-release-provenance.sh"

echo "Native PAM release assets built in $OUTPUT_DIR"
