#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
INPUT_DIR="$ROOT/dist/release"
OUTPUT_DIR="$ROOT/dist/rpm-repository"
SIGNING_KEY="${PWNED_CHECK_RPM_SIGNING_KEY:-}"
PUBLIC_KEY_OUTPUT=""
GPG_PASSPHRASE_FILE="${PWNED_CHECK_GPG_PASSPHRASE_FILE:-}"

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-rpm-repository.sh [OPTIONS]

Generate a signed RPM-family repository from validated
pwned-check-native-pam .rpm artifacts.

Options:
  --input-dir <path>          Directory containing RPM artifacts
                              (default: dist/release)
  --output-dir <path>         Repository output directory
                              (default: dist/rpm-repository)
  --signing-key <key-id>      GPG key id/fingerprint used to sign RPMs and
                              repository metadata
                              (or PWNED_CHECK_RPM_SIGNING_KEY)
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

prime_gpg_agent() {
    [ -n "$GPG_PASSPHRASE_FILE" ] || return 0
    prime_file="$WORK_DIR/gpg-agent-prime.txt"
    printf 'pwned-check rpm signing\n' > "$prime_file"
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
[ -n "$SIGNING_KEY" ] || fail "--signing-key or PWNED_CHECK_RPM_SIGNING_KEY is required"

require_command createrepo_c
require_command gpg
require_command rpm
require_command rpmkeys
require_command rpmsign

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-rpm-repo.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

repo_dir="$WORK_DIR/repo"
mkdir -p "$repo_dir"

found=0
for rpm_file in "$INPUT_DIR"/pwned-check-native-pam-*.rpm; do
    [ -e "$rpm_file" ] || continue
    package="$(rpm -qp --qf '%{NAME}' "$rpm_file")"
    [ "$package" = "pwned-check-native-pam" ] || fail "unexpected package name in $rpm_file: $package"
    cp "$rpm_file" "$repo_dir/"
    found=$((found + 1))
done
[ "$found" -gt 0 ] || fail "no pwned-check-native-pam RPM artifacts found in $INPUT_DIR"

macro_file="$WORK_DIR/.rpmmacros"
cat > "$macro_file" <<EOF
%_gpg_name $SIGNING_KEY
%_openpgp_sign_id $SIGNING_KEY
%__gpg $(command -v gpg)
EOF
gpg --batch --yes --pinentry-mode loopback --armor --export "$SIGNING_KEY" > "$WORK_DIR/rpm-signing-key.asc"
rpm --import "$WORK_DIR/rpm-signing-key.asc"
prime_gpg_agent

for rpm_file in "$repo_dir"/*.rpm; do
    HOME="$WORK_DIR" rpmsign --addsign "$rpm_file" </dev/null
    rpm -Kv "$rpm_file" | grep -Eiq '(pgp|OpenPGP)' || fail "RPM signature missing after signing: $rpm_file"
done

createrepo_c "$repo_dir" >/dev/null

gpg --batch --yes $(gpg_base_args) --local-user "$SIGNING_KEY" \
    --armor --detach-sign --digest-algo SHA256 \
    --output "$repo_dir/repodata/repomd.xml.asc" \
    "$repo_dir/repodata/repomd.xml"

rm -rf "$OUTPUT_DIR"
mkdir -p "$(dirname "$OUTPUT_DIR")"
cp -a "$repo_dir" "$OUTPUT_DIR"

if [ -n "$PUBLIC_KEY_OUTPUT" ]; then
    mkdir -p "$(dirname "$PUBLIC_KEY_OUTPUT")"
    gpg --batch --yes --armor --export "$SIGNING_KEY" > "$PUBLIC_KEY_OUTPUT"
fi

printf 'RPM repository written to %s\n' "$OUTPUT_DIR"
printf 'Signed RPM artifacts: %s\n' "$found"
