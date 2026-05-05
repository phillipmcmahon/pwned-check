#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
INPUT_DIR="$ROOT/dist/release"
OUTPUT_DIR="$ROOT/dist/apt-repository"
SUITE="stable"
COMPONENT="main"
ORIGIN="pwned-check"
LABEL="pwned-check native PAM"
SIGNING_KEY="${PWNED_CHECK_APT_SIGNING_KEY:-}"
PUBLIC_KEY_OUTPUT=""
GPG_PASSPHRASE_FILE="${PWNED_CHECK_GPG_PASSPHRASE_FILE:-}"

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-apt-repository.sh [OPTIONS]

Generate signed apt repository metadata from validated
pwned-check-native-pam .deb artifacts.

Options:
  --input-dir <path>          Directory containing .deb artifacts
                              (default: dist/release)
  --output-dir <path>         Repository output directory
                              (default: dist/apt-repository)
  --suite <name>              Apt suite/codename (default: stable)
  --component <name>          Apt component (default: main)
  --origin <name>             Release metadata Origin field
  --label <name>              Release metadata Label field
  --signing-key <key-id>      GPG key id/fingerprint used to sign metadata
                              (or PWNED_CHECK_APT_SIGNING_KEY)
  --public-key-output <path>  Export the signing public key to this path
  --help                      Show this help text

Environment:
  PWNED_CHECK_GPG_PASSPHRASE_FILE  Optional passphrase file for protected
                                   OpenPGP signing keys
EOF
}

gpg_base_args() {
    if [ -n "$GPG_PASSPHRASE_FILE" ]; then
        printf '%s\n' --pinentry-mode loopback --passphrase-file "$GPG_PASSPHRASE_FILE"
    fi
}

checksum_line() {
    algorithm="$1"
    file="$2"
    rel="$3"
    case "$algorithm" in
        MD5Sum) digest="$(md5sum "$file" | awk '{print $1}')" ;;
        SHA1) digest="$(sha1sum "$file" | awk '{print $1}')" ;;
        SHA256) digest="$(sha256sum "$file" | awk '{print $1}')" ;;
        SHA512) digest="$(sha512sum "$file" | awk '{print $1}')" ;;
        *) fail "unknown checksum algorithm: $algorithm" ;;
    esac
    size="$(wc -c < "$file" | tr -d ' ')"
    printf ' %s %s %s\n' "$digest" "$size" "$rel"
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
        --suite)
            [ "$#" -ge 2 ] || fail "--suite requires a value"
            SUITE="$2"
            shift 2
            ;;
        --component)
            [ "$#" -ge 2 ] || fail "--component requires a value"
            COMPONENT="$2"
            shift 2
            ;;
        --origin)
            [ "$#" -ge 2 ] || fail "--origin requires a value"
            ORIGIN="$2"
            shift 2
            ;;
        --label)
            [ "$#" -ge 2 ] || fail "--label requires a value"
            LABEL="$2"
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
[ -n "$SIGNING_KEY" ] || fail "--signing-key or PWNED_CHECK_APT_SIGNING_KEY is required"

require_command dpkg-deb
require_command dpkg-scanpackages
require_command gzip
require_command gpg
require_command md5sum
require_command sha1sum
require_command sha256sum
require_command sha512sum

case "$SUITE" in
    *[!A-Za-z0-9._+-]*|'') fail "invalid apt suite: $SUITE" ;;
esac
case "$COMPONENT" in
    *[!A-Za-z0-9._+-]*|'') fail "invalid apt component: $COMPONENT" ;;
esac

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-apt-repo.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

POOL_DIR="$WORK_DIR/repo/pool/main/p/pwned-check-native-pam"
mkdir -p "$POOL_DIR"

found=0
for deb in "$INPUT_DIR"/pwned-check-native-pam_*.deb; do
    [ -e "$deb" ] || continue
    package="$(dpkg-deb -f "$deb" Package)"
    [ "$package" = "pwned-check-native-pam" ] || fail "unexpected package name in $deb: $package"
    cp "$deb" "$POOL_DIR/"
    found=$((found + 1))
done
[ "$found" -gt 0 ] || fail "no pwned-check-native-pam .deb artifacts found in $INPUT_DIR"

ARCHES="$(for deb in "$POOL_DIR"/*.deb; do dpkg-deb -f "$deb" Architecture; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
[ -n "$ARCHES" ] || fail "could not determine repository architectures"

for arch in $ARCHES; do
    binary_dir="$WORK_DIR/repo/dists/$SUITE/$COMPONENT/binary-$arch"
    mkdir -p "$binary_dir"
    (
        cd "$WORK_DIR/repo"
        dpkg-scanpackages --arch "$arch" "pool" /dev/null > "dists/$SUITE/$COMPONENT/binary-$arch/Packages"
        gzip -9nc "dists/$SUITE/$COMPONENT/binary-$arch/Packages" > "dists/$SUITE/$COMPONENT/binary-$arch/Packages.gz"
    )
done

release_dir="$WORK_DIR/repo/dists/$SUITE"
release_file="$release_dir/Release"
date_utc="$(date -u '+%a, %d %b %Y %H:%M:%S UTC')"

{
    printf 'Origin: %s\n' "$ORIGIN"
    printf 'Label: %s\n' "$LABEL"
    printf 'Suite: %s\n' "$SUITE"
    printf 'Codename: %s\n' "$SUITE"
    printf 'Date: %s\n' "$date_utc"
    printf 'Architectures: %s\n' "$ARCHES"
    printf 'Components: %s\n' "$COMPONENT"
    printf 'Description: pwned-check native PAM apt repository\n'
    for algorithm in MD5Sum SHA1 SHA256 SHA512; do
        printf '%s:\n' "$algorithm"
        for arch in $ARCHES; do
            for rel in "$COMPONENT/binary-$arch/Packages" "$COMPONENT/binary-$arch/Packages.gz"; do
                checksum_line "$algorithm" "$release_dir/$rel" "$rel"
            done
        done
    done
} > "$release_file"

gpg --batch --yes $(gpg_base_args) --local-user "$SIGNING_KEY" --clearsign \
    --digest-algo SHA256 \
    --output "$release_dir/InRelease" \
    "$release_file"
gpg --batch --yes $(gpg_base_args) --local-user "$SIGNING_KEY" --detach-sign \
    --armor --digest-algo SHA256 \
    --output "$release_dir/Release.gpg" \
    "$release_file"

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
cp -a "$WORK_DIR/repo" "$OUTPUT_DIR"

if [ -n "$PUBLIC_KEY_OUTPUT" ]; then
    mkdir -p "$(dirname "$PUBLIC_KEY_OUTPUT")"
    gpg --batch --yes --armor --export "$SIGNING_KEY" > "$PUBLIC_KEY_OUTPUT"
fi

printf 'Apt repository written to %s\n' "$OUTPUT_DIR"
printf 'Suite: %s\n' "$SUITE"
printf 'Component: %s\n' "$COMPONENT"
printf 'Architectures: %s\n' "$ARCHES"
