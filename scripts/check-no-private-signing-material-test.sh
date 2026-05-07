#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-no-private-signing-material.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
    echo "Error: $*" >&2
    exit 1
}

expect_pass() {
    "$GUARD" "$@" >/dev/null 2>&1 || fail "expected guard to pass: $*"
}

expect_fail() {
    if "$GUARD" "$@" >/dev/null 2>&1; then
        fail "expected guard to fail: $*"
    fi
}

SAFE_DIR="$TMP_DIR/safe"
mkdir -p "$SAFE_DIR"
printf '%s\n' 'public OpenPGP key placeholder' > "$SAFE_DIR/pwned-check-openpgp-production.asc"
printf '%s\n' 'BDF6F4DD343E9F10EA9DB510FDDA2848A95AD641' > "$SAFE_DIR/pwned-check-openpgp-production.fingerprint.txt"
printf '%s\n' 'public Alpine RSA key placeholder' > "$SAFE_DIR/pwned-check-alpine-production.rsa.pub"
expect_pass "$SAFE_DIR"

PRIVATE_MARKER_DIR="$TMP_DIR/private-marker"
mkdir -p "$PRIVATE_MARKER_DIR"
printf '%s%s%s\n' '-----BEGIN ' 'PGP PRIVATE KEY BLOCK' '-----' > "$PRIVATE_MARKER_DIR/key.asc"
expect_fail "$PRIVATE_MARKER_DIR"

PASSPHRASE_DIR="$TMP_DIR/passphrase-name"
mkdir -p "$PASSPHRASE_DIR"
printf '%s\n' 'not secret fixture content' > "$PASSPHRASE_DIR/openpgp-passphrase.txt"
expect_fail "$PASSPHRASE_DIR"

GNUPG_DIR="$TMP_DIR/gnupg-storage"
mkdir -p "$GNUPG_DIR/.gnupg"
printf '%s\n' 'placeholder' > "$GNUPG_DIR/.gnupg/pubring.kbx"
expect_fail "$GNUPG_DIR"

ALPINE_PRIVATE_DIR="$TMP_DIR/alpine-private"
mkdir -p "$ALPINE_PRIVATE_DIR"
printf '%s\n' 'placeholder' > "$ALPINE_PRIVATE_DIR/pwned-check-alpine-production.rsa"
expect_fail "$ALPINE_PRIVATE_DIR"

echo "private signing material guard tests passed"
