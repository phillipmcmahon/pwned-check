#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CARGO_TOML="$ROOT/native/pam-pwned-check/Cargo.toml"
CARGO_LOCK="$ROOT/Cargo.lock"

usage() {
    cat <<'EOF'
Usage: ./scripts/prepare-release-version.sh --version <version>

Update release version metadata that must move together during release prep.

The version may be passed with or without a leading "v". The script updates the
native PAM Rust crate version in Cargo.toml, refreshes Cargo.lock, and verifies
both files agree.
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

VERSION=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
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
VERSION="${VERSION#v}"
case "$VERSION" in
    *[!0-9.]* | .* | *..* | *.)
        fail "version must be a dotted numeric release version, got: $VERSION"
        ;;
    *)
        ;;
esac

require_command cargo
require_command perl

PWNED_CHECK_RELEASE_VERSION="$VERSION" \
    perl -0pi -e 's/(^\[package\]\n(?:[^\[]*\n)*?^version = ")[^"]+(")/$1$ENV{PWNED_CHECK_RELEASE_VERSION}$2/m' "$CARGO_TOML"

(
    cd "$ROOT"
    cargo check -p pam-pwned-check >/dev/null
)

toml_version="$(awk '
    /^\[package\]$/ { in_package = 1; next }
    /^\[/ { in_package = 0 }
    in_package && /^version = / {
        gsub(/"/, "", $3)
        print $3
        exit
    }
' "$CARGO_TOML")"

lock_version="$(awk '
    /^\[\[package\]\]$/ { in_package = 0; name = ""; version = ""; next }
    /^name = "pam-pwned-check"$/ { in_package = 1; name = "pam-pwned-check"; next }
    in_package && /^version = / {
        gsub(/"/, "", $3)
        print $3
        exit
    }
' "$CARGO_LOCK")"

[ "$toml_version" = "$VERSION" ] || fail "$CARGO_TOML has version $toml_version, expected $VERSION"
[ "$lock_version" = "$VERSION" ] || fail "$CARGO_LOCK has pam-pwned-check version $lock_version, expected $VERSION"

printf 'Release version metadata prepared for %s\n' "$VERSION"
