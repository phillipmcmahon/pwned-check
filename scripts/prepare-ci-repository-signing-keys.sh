#!/usr/bin/env bash

set -euo pipefail

OUTPUT_DIR=""

usage() {
    cat <<'EOF'
Usage: scripts/prepare-ci-repository-signing-keys.sh --output-dir <runner-temp-child>

Materialize CI repository signing secrets into a validated key directory under
$RUNNER_TEMP. The script reads PWNED_CHECK_CI_* environment variables and writes
filenames compatible with scripts/build-native-pam-repositories-docker.sh.

Required environment:
  RUNNER_TEMP
  PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY
  PWNED_CHECK_CI_OPENPGP_SECRET_KEY
  PWNED_CHECK_CI_OPENPGP_FINGERPRINT
  PWNED_CHECK_CI_OPENPGP_PASSPHRASE
  PWNED_CHECK_CI_ALPINE_PRIVATE_KEY
  PWNED_CHECK_CI_ALPINE_PUBLIC_KEY
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_env() {
    name="$1"
    eval "value=\${$name:-}"
    [ -n "$value" ] || fail "required environment variable is empty: $name"
}

mask_value() {
    value="$1"
    [ "${GITHUB_ACTIONS:-}" = "true" ] || return 0

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        printf '::add-mask::%s\n' "$line"
    done <<EOF
$value
EOF
}

write_file() {
    path="$1"
    mode="$2"
    value="$3"

    printf '%s\n' "$value" > "$path"
    chmod "$mode" "$path"
}

fingerprint_from_key() {
    key_file="$1"
    gpg --batch --import-options show-only --import --with-colons "$key_file" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}' \
        || true
}

canonical_dir() {
    path="$1"
    mkdir -p "$path"
    (cd "$path" && pwd -P)
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-dir)
            [ "$#" -ge 2 ] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
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

[ -n "$OUTPUT_DIR" ] || fail "--output-dir is required"
[ -n "${RUNNER_TEMP:-}" ] || fail "RUNNER_TEMP must be set"

require_command gpg
require_command openssl

require_env PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY
require_env PWNED_CHECK_CI_OPENPGP_SECRET_KEY
require_env PWNED_CHECK_CI_OPENPGP_FINGERPRINT
require_env PWNED_CHECK_CI_OPENPGP_PASSPHRASE
require_env PWNED_CHECK_CI_ALPINE_PRIVATE_KEY
require_env PWNED_CHECK_CI_ALPINE_PUBLIC_KEY

mask_value "$PWNED_CHECK_CI_OPENPGP_SECRET_KEY"
mask_value "$PWNED_CHECK_CI_OPENPGP_PASSPHRASE"
mask_value "$PWNED_CHECK_CI_ALPINE_PRIVATE_KEY"

RUNNER_TEMP_REAL="$(canonical_dir "$RUNNER_TEMP")"
OUTPUT_DIR_REAL="$(canonical_dir "$OUTPUT_DIR")"
case "$OUTPUT_DIR_REAL/" in
    "$RUNNER_TEMP_REAL"/*) ;;
    *) fail "output directory must be a child of RUNNER_TEMP: $OUTPUT_DIR_REAL" ;;
esac

umask 077

OPENPGP_PUBLIC_FILE="$OUTPUT_DIR_REAL/pwned-check-openpgp-production.asc"
OPENPGP_SECRET_FILE="$OUTPUT_DIR_REAL/pwned-check-openpgp-production-secret.asc"
OPENPGP_FINGERPRINT_FILE="$OUTPUT_DIR_REAL/pwned-check-openpgp-production.fingerprint.txt"
OPENPGP_PASSPHRASE_FILE="$OUTPUT_DIR_REAL/pwned-check-openpgp-passphrase.txt"
ALPINE_PRIVATE_FILE="$OUTPUT_DIR_REAL/pwned-check-alpine-production.rsa"
ALPINE_PUBLIC_FILE="$OUTPUT_DIR_REAL/pwned-check-alpine-production.rsa.pub"

write_file "$OPENPGP_PUBLIC_FILE" 0644 "$PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY"
write_file "$OPENPGP_SECRET_FILE" 0600 "$PWNED_CHECK_CI_OPENPGP_SECRET_KEY"
write_file "$OPENPGP_FINGERPRINT_FILE" 0644 "$PWNED_CHECK_CI_OPENPGP_FINGERPRINT"
write_file "$OPENPGP_PASSPHRASE_FILE" 0600 "$PWNED_CHECK_CI_OPENPGP_PASSPHRASE"
write_file "$ALPINE_PRIVATE_FILE" 0600 "$PWNED_CHECK_CI_ALPINE_PRIVATE_KEY"
write_file "$ALPINE_PUBLIC_FILE" 0644 "$PWNED_CHECK_CI_ALPINE_PUBLIC_KEY"

EXPECTED_FINGERPRINT="$(tr -d '[:space:]' < "$OPENPGP_FINGERPRINT_FILE" | tr '[:lower:]' '[:upper:]')"
case "$EXPECTED_FINGERPRINT" in
    (*[!0123456789ABCDEF]*|'') fail "OpenPGP fingerprint must be hexadecimal" ;;
esac
[ "${#EXPECTED_FINGERPRINT}" -eq 40 ] || fail "OpenPGP fingerprint must be 40 hexadecimal characters"
printf '%s\n' "$EXPECTED_FINGERPRINT" > "$OPENPGP_FINGERPRINT_FILE"

armor_begin='-----BEGIN '
armor_end='-----'
private_key_re="${armor_begin}"'[A-Z0-9 ]*PRIVATE KEY( BLOCK)?'"${armor_end}"

if LC_ALL=C grep -Eq -e "$private_key_re" "$OPENPGP_PUBLIC_FILE"; then
    fail "OpenPGP public key contains private-key material"
fi
if ! LC_ALL=C grep -Eq -e "$private_key_re" "$OPENPGP_SECRET_FILE"; then
    fail "OpenPGP secret key does not contain private-key material"
fi
if ! LC_ALL=C grep -Eq -e "$private_key_re" "$ALPINE_PRIVATE_FILE"; then
    fail "Alpine private key does not contain private-key material"
fi
if LC_ALL=C grep -Eq -e "$private_key_re" "$ALPINE_PUBLIC_FILE"; then
    fail "Alpine public key contains private-key material"
fi

VALIDATION_GNUPGHOME="$RUNNER_TEMP_REAL/pwned-check-ci-key-validation-$$"
mkdir -m 0700 "$VALIDATION_GNUPGHOME"
trap 'rm -rf "$VALIDATION_GNUPGHOME"' EXIT INT TERM
export GNUPGHOME="$VALIDATION_GNUPGHOME"

PUBLIC_FINGERPRINT="$(fingerprint_from_key "$OPENPGP_PUBLIC_FILE")"
SECRET_FINGERPRINT="$(fingerprint_from_key "$OPENPGP_SECRET_FILE")"
[ "$PUBLIC_FINGERPRINT" = "$EXPECTED_FINGERPRINT" ] || fail "OpenPGP public key fingerprint mismatch"
[ "$SECRET_FINGERPRINT" = "$EXPECTED_FINGERPRINT" ] || fail "OpenPGP secret key fingerprint mismatch"

DERIVED_ALPINE_PUBLIC="$OUTPUT_DIR_REAL/.derived-alpine-public.pem"
openssl pkey -in "$ALPINE_PRIVATE_FILE" -pubout -out "$DERIVED_ALPINE_PUBLIC" >/dev/null 2>&1 \
    || fail "failed to derive Alpine public key from private key"
chmod 0600 "$DERIVED_ALPINE_PUBLIC"
if ! cmp -s "$DERIVED_ALPINE_PUBLIC" "$ALPINE_PUBLIC_FILE"; then
    fail "Alpine private/public key pair mismatch"
fi
rm -f "$DERIVED_ALPINE_PUBLIC"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        printf 'key-dir=%s\n' "$OUTPUT_DIR_REAL"
        printf 'openpgp-secret-key-file=%s\n' "$OPENPGP_SECRET_FILE"
    } >> "$GITHUB_OUTPUT"
fi

echo "CI repository signing keys prepared: $OUTPUT_DIR_REAL"
