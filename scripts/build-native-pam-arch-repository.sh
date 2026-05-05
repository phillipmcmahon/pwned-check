#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INPUT_DIR="$ROOT/dist/release"
OUTPUT_DIR="$ROOT/dist/arch-repository"
REPO_NAME="pwned-check"
SIGNING_KEY="${PWNED_CHECK_ARCH_SIGNING_KEY:-}"
PUBLIC_KEY_OUTPUT=""
GPG_PASSPHRASE_FILE="${PWNED_CHECK_GPG_PASSPHRASE_FILE:-}"

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-arch-repository.sh [OPTIONS]

Generate a signed Arch custom repository from validated
pwned-check-native-pam .pkg.tar.zst artifacts.

Options:
  --input-dir <path>          Directory containing Arch package artifacts
                              (default: dist/release)
  --output-dir <path>         Repository output directory
                              (default: dist/arch-repository)
  --repo-name <name>          pacman repository name (default: pwned-check)
  --signing-key <key-id>      GPG key ID/fingerprint used for package and
                              repository database signatures
                              (or PWNED_CHECK_ARCH_SIGNING_KEY)
  --public-key-output <path>  Export the public key to this path
  --help                      Show this help text

Environment:
  PWNED_CHECK_GPG_PASSPHRASE_FILE  Optional passphrase file for protected
                                   OpenPGP signing keys
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

gpg_base_args() {
    if [ -n "$GPG_PASSPHRASE_FILE" ]; then
        printf '%s\n' --pinentry-mode loopback --passphrase-file "$GPG_PASSPHRASE_FILE"
    fi
}

prime_gpg_agent() {
    [ -n "$GPG_PASSPHRASE_FILE" ] || return 0
    prime_file="$WORK_DIR/gpg-agent-prime.txt"
    printf 'pwned-check arch signing\n' > "$prime_file"
    gpg --batch --yes $(gpg_base_args) --local-user "$SIGNING_KEY" \
        --armor --detach-sign --output "$prime_file.asc" "$prime_file" >/dev/null
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
        --repo-name)
            [ "$#" -ge 2 ] || fail "--repo-name requires a value"
            REPO_NAME="$2"
            shift 2
            ;;
        --signing-key)
            [ "$#" -ge 2 ] || fail "--signing-key requires a value"
            SIGNING_KEY="$2"
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
[ -n "$SIGNING_KEY" ] || fail "--signing-key or PWNED_CHECK_ARCH_SIGNING_KEY is required"

require_command gpg
require_command repo-add
require_command tar
require_command zstd

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-arch-repo.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

repo_dir="$WORK_DIR/repo"
mkdir -p "$repo_dir"
prime_gpg_agent

found=0
for pkg_file in "$INPUT_DIR"/pwned-check-native-pam-*.pkg.tar.zst; do
    [ -e "$pkg_file" ] || continue
    pkginfo="$(zstd -dc "$pkg_file" | tar -xO .PKGINFO)"
    pkgname="$(printf '%s\n' "$pkginfo" | awk -F' = ' '/^pkgname/ {print $2; exit}')"
    arch="$(printf '%s\n' "$pkginfo" | awk -F' = ' '/^arch/ {print $2; exit}')"
    [ "$pkgname" = "pwned-check-native-pam" ] || fail "unexpected package name in $pkg_file: $pkgname"
    [ -n "$arch" ] || fail "could not determine Arch package architecture for $pkg_file"
    mkdir -p "$repo_dir/$arch"
    cp "$pkg_file" "$repo_dir/$arch/"
    gpg --batch --yes $(gpg_base_args) --detach-sign --local-user "$SIGNING_KEY" "$repo_dir/$arch/$(basename "$pkg_file")"
    found=$((found + 1))
done
[ "$found" -gt 0 ] || fail "no pwned-check-native-pam Arch packages found in $INPUT_DIR"

for arch_dir in "$repo_dir"/*; do
    [ -d "$arch_dir" ] || continue
    (
        cd "$arch_dir"
        repo-add --sign --key "$SIGNING_KEY" "$REPO_NAME.db.tar.zst" ./*.pkg.tar.zst >/dev/null
    )
done

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
cp -a "$repo_dir" "$OUTPUT_DIR"

if [ -n "$PUBLIC_KEY_OUTPUT" ]; then
    mkdir -p "$(dirname "$PUBLIC_KEY_OUTPUT")"
    gpg --batch --armor --export "$SIGNING_KEY" > "$PUBLIC_KEY_OUTPUT"
fi

printf 'Arch repository written to %s\n' "$OUTPUT_DIR"
printf 'Indexed Arch package artifacts: %s\n' "$found"
