#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/prepare-ci-repository-signing-keys.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

file_mode() {
    path="$1"
    mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
    case "$mode" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7])
            printf '%s\n' "$mode"
            return
            ;;
    esac
    stat -c '%a' "$path"
}

require_command gpg
require_command openssl

GNUPGHOME="$TMP_DIR/gnupg"
export GNUPGHOME
mkdir -m 0700 "$GNUPGHOME"

cat > "$TMP_DIR/key-params" <<'EOF'
Key-Type: RSA
Key-Length: 2048
Key-Usage: sign
Name-Real: Pwned Check CI Test
Name-Email: pwned-check-ci-test@example.invalid
Expire-Date: 0
%no-protection
%commit
EOF

gpg --batch --generate-key "$TMP_DIR/key-params" >/dev/null 2>&1
OPENPGP_FINGERPRINT="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')"
[ -n "$OPENPGP_FINGERPRINT" ] || fail "failed to generate OpenPGP test key"
gpg --batch --armor --export "$OPENPGP_FINGERPRINT" > "$TMP_DIR/openpgp-public.asc"
gpg --batch --armor --export-secret-keys "$OPENPGP_FINGERPRINT" > "$TMP_DIR/openpgp-secret.asc"

openssl genrsa -out "$TMP_DIR/alpine-private.rsa" 2048 >/dev/null 2>&1
openssl pkey -in "$TMP_DIR/alpine-private.rsa" -pubout -out "$TMP_DIR/alpine-public.rsa.pub" >/dev/null 2>&1

RUNNER_TEMP="$TMP_DIR/runner"
OUTPUT_DIR="$RUNNER_TEMP/signing-keys"
mkdir -p "$RUNNER_TEMP"

env \
    RUNNER_TEMP="$RUNNER_TEMP" \
    PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY="$(cat "$TMP_DIR/openpgp-public.asc")" \
    PWNED_CHECK_CI_OPENPGP_SECRET_KEY="$(cat "$TMP_DIR/openpgp-secret.asc")" \
    PWNED_CHECK_CI_OPENPGP_FINGERPRINT="$OPENPGP_FINGERPRINT" \
    PWNED_CHECK_CI_OPENPGP_PASSPHRASE="ci-test-passphrase" \
    PWNED_CHECK_CI_ALPINE_PRIVATE_KEY="$(cat "$TMP_DIR/alpine-private.rsa")" \
    PWNED_CHECK_CI_ALPINE_PUBLIC_KEY="$(cat "$TMP_DIR/alpine-public.rsa.pub")" \
    "$SCRIPT" --output-dir "$OUTPUT_DIR" >/dev/null

[ -f "$OUTPUT_DIR/pwned-check-openpgp-production.asc" ] || fail "OpenPGP public key was not written"
[ -f "$OUTPUT_DIR/pwned-check-openpgp-production-secret.asc" ] || fail "OpenPGP secret key was not written"
[ -f "$OUTPUT_DIR/pwned-check-openpgp-production.fingerprint.txt" ] || fail "OpenPGP fingerprint was not written"
[ -f "$OUTPUT_DIR/pwned-check-openpgp-passphrase.txt" ] || fail "OpenPGP passphrase was not written"
[ -f "$OUTPUT_DIR/pwned-check-alpine-production.rsa" ] || fail "Alpine private key was not written"
[ -f "$OUTPUT_DIR/pwned-check-alpine-production.rsa.pub" ] || fail "Alpine public key was not written"

[ "$(cat "$OUTPUT_DIR/pwned-check-openpgp-production.fingerprint.txt")" = "$OPENPGP_FINGERPRINT" ] || fail "fingerprint was not normalized as expected"

secret_mode="$(file_mode "$OUTPUT_DIR/pwned-check-openpgp-production-secret.asc")"
passphrase_mode="$(file_mode "$OUTPUT_DIR/pwned-check-openpgp-passphrase.txt")"
alpine_private_mode="$(file_mode "$OUTPUT_DIR/pwned-check-alpine-production.rsa")"
[ "$secret_mode" = "600" ] || fail "OpenPGP secret key mode is $secret_mode, expected 600"
[ "$passphrase_mode" = "600" ] || fail "OpenPGP passphrase mode is $passphrase_mode, expected 600"
[ "$alpine_private_mode" = "600" ] || fail "Alpine private key mode is $alpine_private_mode, expected 600"

if env \
    RUNNER_TEMP="$RUNNER_TEMP" \
    PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY="$(cat "$TMP_DIR/openpgp-public.asc")" \
    PWNED_CHECK_CI_OPENPGP_SECRET_KEY="$(cat "$TMP_DIR/openpgp-secret.asc")" \
    PWNED_CHECK_CI_OPENPGP_FINGERPRINT="0000000000000000000000000000000000000000" \
    PWNED_CHECK_CI_OPENPGP_PASSPHRASE="ci-test-passphrase" \
    PWNED_CHECK_CI_ALPINE_PRIVATE_KEY="$(cat "$TMP_DIR/alpine-private.rsa")" \
    PWNED_CHECK_CI_ALPINE_PUBLIC_KEY="$(cat "$TMP_DIR/alpine-public.rsa.pub")" \
    "$SCRIPT" --output-dir "$OUTPUT_DIR-bad" >/dev/null 2>&1; then
    fail "expected fingerprint mismatch to fail"
fi

if env \
    RUNNER_TEMP="$RUNNER_TEMP" \
    PWNED_CHECK_CI_OPENPGP_PUBLIC_KEY="$(cat "$TMP_DIR/openpgp-public.asc")" \
    PWNED_CHECK_CI_OPENPGP_SECRET_KEY="$(cat "$TMP_DIR/openpgp-secret.asc")" \
    PWNED_CHECK_CI_OPENPGP_FINGERPRINT="$OPENPGP_FINGERPRINT" \
    PWNED_CHECK_CI_OPENPGP_PASSPHRASE="ci-test-passphrase" \
    PWNED_CHECK_CI_ALPINE_PRIVATE_KEY="$(cat "$TMP_DIR/alpine-private.rsa")" \
    PWNED_CHECK_CI_ALPINE_PUBLIC_KEY="$(cat "$TMP_DIR/alpine-private.rsa")" \
    "$SCRIPT" --output-dir "$OUTPUT_DIR-bad-alpine" >/dev/null 2>&1; then
    fail "expected Alpine public/private mismatch to fail"
fi

echo "CI repository signing key preparation tests passed"
