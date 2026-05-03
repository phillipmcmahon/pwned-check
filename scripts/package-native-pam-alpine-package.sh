#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="${SOURCE_DATE_EPOCH:-}"
PWNED_CHECK_BIN=""

usage() {
    cat <<'EOF'
Usage: scripts/package-native-pam-alpine-package.sh --version <version> [OPTIONS]

Build an Alpine .apk package from the generic native PAM filesystem-layout
artifact and the APKBUILD template under packaging/alpine/.

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
    echo "native PAM Alpine package skipped: Linux host required" >&2
    exit 0
fi

require_command abuild
require_command openssl
require_command sha256sum
require_command sha512sum
require_command tar

[ -z "$PWNED_CHECK_BIN" ] || [ -x "$PWNED_CHECK_BIN" ] || fail "--pwned-check-bin is not executable: $PWNED_CHECK_BIN"

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

PKGVER="$(printf '%s' "$VERSION" | sed 's/^v//; s/-rc/_rc/g; s/[^A-Za-z0-9._]/./g; s/\.\.\*/./g; s/^\.//; s/\.$//')"
[ -n "$PKGVER" ] || PKGVER=0
case "$PKGVER" in
    [0-9]*) ;;
    *) PKGVER="0_$PKGVER" ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-alpine-package.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

ARTIFACT_OUT="$WORK_DIR/artifacts"
BUILD_DIR="$WORK_DIR/build"
mkdir -p "$ARTIFACT_OUT" "$BUILD_DIR" "$OUTPUT_DIR"

if [ -n "$PWNED_CHECK_BIN" ]; then
    artifact_name="$(cd "$ROOT" && ./scripts/package-native-pam-generic-artifact.sh --version "$VERSION" --family alpine --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME" --pwned-check-bin "$PWNED_CHECK_BIN")"
else
    artifact_name="$(cd "$ROOT" && ./scripts/package-native-pam-generic-artifact.sh --version "$VERSION" --family alpine --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME")"
fi
artifact="$ARTIFACT_OUT/$artifact_name.tar.gz"
[ -f "$artifact" ] || fail "artifact was not produced: $artifact"
artifact_base="$(basename "$artifact")"
artifact_sha="$(sha512sum "$artifact" | awk '{print $1}')"
cp "$artifact" "$BUILD_DIR/$artifact_base"

sed \
    -e "s/@PKGVER@/$PKGVER/g" \
    -e "s/@ARTIFACT@/$artifact_base/g" \
    -e "s/@SHA512@/$artifact_sha/g" \
    -e "s/@ARTIFACT_DIR@/$artifact_name/g" \
    "$ROOT/packaging/alpine/APKBUILD.in" > "$BUILD_DIR/APKBUILD"

prepare_abuild_key() {
    user_home="$1"
    key_dir="$user_home/.abuild"
    key_path="$key_dir/pwned-check-native-pam.rsa"
    mkdir -p "$key_dir"
    if [ ! -f "$key_path" ]; then
        openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
        openssl rsa -in "$key_path" -pubout -out "$key_path.pub" >/dev/null 2>&1
    fi
    {
        printf 'PACKAGER_PRIVKEY="%s"\n' "$key_path"
        printf 'REPODEST="%s/packages"\n' "$WORK_DIR"
    } > "$key_dir/abuild.conf"
    if [ "$(id -u)" -eq 0 ]; then
        mkdir -p /etc/apk/keys
        cp "$key_path.pub" /etc/apk/keys/
    elif command -v sudo >/dev/null 2>&1; then
        sudo mkdir -p /etc/apk/keys
        sudo cp "$key_path.pub" /etc/apk/keys/
    fi
}

run_abuild() {
    cd "$BUILD_DIR"
    abuild -r >&2
}

if [ "$(id -u)" -eq 0 ]; then
    BUILD_USER="pwnedbuild"
    if ! id "$BUILD_USER" >/dev/null 2>&1; then
        adduser -D "$BUILD_USER"
    fi
    addgroup "$BUILD_USER" abuild >/dev/null 2>&1 || true
    prepare_abuild_key "/home/$BUILD_USER"
    chown -R "$BUILD_USER:$BUILD_USER" "$WORK_DIR" "/home/$BUILD_USER/.abuild"
    su "$BUILD_USER" -c "cd '$BUILD_DIR' && abuild -r" >&2
else
    prepare_abuild_key "$HOME"
    run_abuild
fi

apk_path="$(
    {
        find "$WORK_DIR/packages" -type f -name 'pwned-check-native-pam-*.apk' 2>/dev/null || true
        if [ "$(id -u)" -eq 0 ]; then
            find "/home/$BUILD_USER/packages" -type f -name 'pwned-check-native-pam-*.apk' 2>/dev/null || true
        elif [ -n "${HOME:-}" ]; then
            find "$HOME/packages" -type f -name 'pwned-check-native-pam-*.apk' 2>/dev/null || true
        fi
    } | sort | tail -n 1
)"
[ -n "$apk_path" ] || fail "Alpine package was not produced"
apk_name="$(basename "$apk_path")"
cp "$apk_path" "$OUTPUT_DIR/$apk_name"

metadata="$OUTPUT_DIR/$apk_name.build-metadata.json"
cat > "$metadata" <<EOF
{
  "version": "$VERSION",
  "pkgver": "$PKGVER",
  "package": "$apk_name",
  "source_artifact": "$artifact_base",
  "build_time": "$BUILD_TIME"
}
EOF

(
    cd "$OUTPUT_DIR"
    sha256sum "$apk_name" > "$apk_name.sha256"
    sha256sum "$(basename "$metadata")" > "$(basename "$metadata").sha256"
)

printf '%s\n' "$apk_name"
