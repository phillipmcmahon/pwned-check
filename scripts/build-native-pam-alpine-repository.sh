#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
INPUT_DIR="$ROOT/dist/release"
OUTPUT_DIR="$ROOT/dist/alpine-repository"
PRIVATE_KEY="${PWNED_CHECK_ALPINE_SIGNING_KEY:-}"
PUBLIC_KEY_OUTPUT=""

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-alpine-repository.sh [OPTIONS]

Generate a signed Alpine APK repository from validated
pwned-check-native-pam .apk artifacts.

Options:
  --input-dir <path>          Directory containing APK artifacts
                              (default: dist/release)
  --output-dir <path>         Repository output directory
                              (default: dist/alpine-repository)
  --signing-key <path>        RSA private key used to sign APKINDEX.tar.gz
                              (or PWNED_CHECK_ALPINE_SIGNING_KEY)
  --public-key-output <path>  Copy/export the public key to this path
  --help                      Show this help text
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input-dir)
            [ "$#" -ge 2 ] || fail "--input-dir requires a value"
            INPUT_DIR="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --signing-key)
            [ "$#" -ge 2 ] || fail "--signing-key requires a value"
            PRIVATE_KEY="$2"
            shift 2
            ;;
        --public-key-output)
            [ "$#" -ge 2 ] || fail "--public-key-output requires a value"
            PUBLIC_KEY_OUTPUT="$2"
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

[ -d "$INPUT_DIR" ] || fail "input directory does not exist: $INPUT_DIR"
[ -n "$PRIVATE_KEY" ] || fail "--signing-key or PWNED_CHECK_ALPINE_SIGNING_KEY is required"
[ -f "$PRIVATE_KEY" ] || fail "signing key does not exist: $PRIVATE_KEY"

require_command abuild-sign
require_command apk
require_command openssl
require_command tar

PUBLIC_KEY="$PRIVATE_KEY.pub"
if [ ! -f "$PUBLIC_KEY" ]; then
    openssl rsa -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-alpine-repo.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

repo_dir="$WORK_DIR/repo"
mkdir -p "$repo_dir"

found=0
for apk_file in "$INPUT_DIR"/pwned-check-native-pam-*.apk; do
    [ -e "$apk_file" ] || continue
    pkginfo="$(tar -xzOf "$apk_file" .PKGINFO)"
    pkgname="$(printf '%s\n' "$pkginfo" | awk -F' = ' '/^pkgname/ {print $2; exit}')"
    pkgver="$(printf '%s\n' "$pkginfo" | awk -F' = ' '/^pkgver/ {print $2; exit}')"
    arch="$(printf '%s\n' "$pkginfo" | awk -F' = ' '/^arch/ {print $2; exit}')"
    [ "$pkgname" = "pwned-check-native-pam" ] || fail "unexpected package name in $apk_file: $pkgname"
    [ -n "$pkgver" ] || fail "could not determine APK version for $apk_file"
    [ -n "$arch" ] || fail "could not determine APK architecture for $apk_file"
    mkdir -p "$repo_dir/$arch"
    cp "$apk_file" "$repo_dir/$arch/$pkgname-$pkgver.apk"
    found=$((found + 1))
done
[ "$found" -gt 0 ] || fail "no pwned-check-native-pam APK artifacts found in $INPUT_DIR"

for arch_dir in "$repo_dir"/*; do
    [ -d "$arch_dir" ] || continue
    (
        cd "$arch_dir"
        apk index --allow-untrusted -o APKINDEX.tar.gz ./*.apk >/dev/null
        abuild-sign -k "$PRIVATE_KEY" APKINDEX.tar.gz >/dev/null
    )
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
cp -a "$repo_dir" "$OUTPUT_DIR"

if [ -n "$PUBLIC_KEY_OUTPUT" ]; then
    mkdir -p "$(dirname "$PUBLIC_KEY_OUTPUT")"
    cp "$PUBLIC_KEY" "$PUBLIC_KEY_OUTPUT"
fi

printf 'Alpine repository written to %s\n' "$OUTPUT_DIR"
printf 'Indexed APK artifacts: %s\n' "$found"
