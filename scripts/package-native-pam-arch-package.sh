#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="${SOURCE_DATE_EPOCH:-}"
PWNED_CHECK_BIN=""

usage() {
    cat <<'EOF'
Usage: scripts/package-native-pam-arch-package.sh --version <version> [OPTIONS]

Build an Arch Linux package from the shared service-file native PAM rootfs
tarball and the PKGBUILD template under packaging/arch/.

Options:
  --version <version>        Version label embedded in package metadata
  --output-dir <dir>         Output directory (default: dist/release)
  --build-time <timestamp>   Build timestamp metadata
  --pwned-check-bin <path>   Use an existing Linux pwned-check binary
  --help                     Show this help text
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
        --pwned-check-bin)
            [ "$#" -ge 2 ] || fail "--pwned-check-bin requires a value"
            PWNED_CHECK_BIN="$2"
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

if [ "$(uname -s)" != "Linux" ]; then
    echo "native PAM Arch package skipped: Linux host required" >&2
    exit 0
fi

require_command makepkg
require_command sha256sum
require_command tar

[ -z "$PWNED_CHECK_BIN" ] || [ -x "$PWNED_CHECK_BIN" ] || fail "--pwned-check-bin is not executable: $PWNED_CHECK_BIN"

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

PKGVER="$(printf '%s' "$VERSION" | sed 's/^v//; s/[^A-Za-z0-9._+]/_/g')"
[ -n "$PKGVER" ] || PKGVER=0

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-arch-package.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

ARTIFACT_OUT="$WORK_DIR/artifacts"
BUILD_DIR="$WORK_DIR/build"
mkdir -p "$ARTIFACT_OUT" "$BUILD_DIR" "$OUTPUT_DIR"

# Arch and Alpine intentionally share the service-file rootfs builder because
# both package families install the same explicit PAM service-file wrappers.
if [ -n "$PWNED_CHECK_BIN" ]; then
    artifact_name="$(cd "$ROOT" && ./scripts/lib/package-native-pam-service-rootfs.sh --version "$VERSION" --family arch --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME" --pwned-check-bin "$PWNED_CHECK_BIN")"
else
    artifact_name="$(cd "$ROOT" && ./scripts/lib/package-native-pam-service-rootfs.sh --version "$VERSION" --family arch --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME")"
fi
artifact="$ARTIFACT_OUT/$artifact_name.tar.gz"
[ -f "$artifact" ] || fail "artifact was not produced: $artifact"
artifact_base="$(basename "$artifact")"
artifact_sha="$(sha256sum "$artifact" | awk '{print $1}')"
cp "$artifact" "$BUILD_DIR/$artifact_base"

sed \
    -e "s/@PKGVER@/$PKGVER/g" \
    -e "s/@ARTIFACT@/$artifact_base/g" \
    -e "s/@SHA256@/$artifact_sha/g" \
    -e "s/@ARTIFACT_DIR@/$artifact_name/g" \
    "$ROOT/packaging/arch/PKGBUILD.in" > "$BUILD_DIR/PKGBUILD"

run_makepkg() {
    cd "$BUILD_DIR"
    makepkg --force --noconfirm >&2
}

if [ "$(id -u)" -eq 0 ]; then
    BUILD_USER="pwnedbuild"
    if ! id "$BUILD_USER" >/dev/null 2>&1; then
        useradd -m "$BUILD_USER"
    fi
    chown -R "$BUILD_USER:$BUILD_USER" "$WORK_DIR"
    su "$BUILD_USER" -c "cd '$BUILD_DIR' && makepkg --force --noconfirm" >&2
else
    run_makepkg
fi

pkg_path="$(find "$BUILD_DIR" -maxdepth 1 -type f -name 'pwned-check-native-pam-*.pkg.tar.*' | sort | tail -n 1)"
[ -n "$pkg_path" ] || fail "Arch package was not produced"
pkg_name="$(basename "$pkg_path")"
cp "$pkg_path" "$OUTPUT_DIR/$pkg_name"

metadata="$OUTPUT_DIR/$pkg_name.build-metadata.json"
cat > "$metadata" <<EOF
{
  "version": "$VERSION",
  "pkgver": "$PKGVER",
  "package": "$pkg_name",
  "source_artifact": "$artifact_base",
  "build_time": "$BUILD_TIME"
}
EOF

(
    cd "$OUTPUT_DIR"
    sha256sum "$pkg_name" > "$pkg_name.sha256"
    sha256sum "$(basename "$metadata")" > "$(basename "$metadata").sha256"
)

printf '%s\n' "$pkg_name"
