#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-memory-check.sh

Run native PAM Rust argv parser tests under Valgrind when available.

The script skips cleanly on non-Linux hosts or hosts without Valgrind so local
macOS development remains lightweight. Linux CI installs Valgrind and treats
reported memory errors as a failure.
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

if [ "$(uname -s)" != "Linux" ]; then
    echo "native PAM memory check skipped: Linux host required"
    exit 0
fi

if ! command -v valgrind >/dev/null 2>&1; then
    echo "native PAM memory check skipped: valgrind not installed"
    exit 0
fi

cd "$ROOT"
cargo test -p pam-pwned-check --lib --no-run

test_bin="$(
    find target/debug/deps -maxdepth 1 -type f -perm -111 -name 'pam_pwned_check-*' ! -name '*.d' \
        | sort \
        | head -n 1
)"
[ -n "$test_bin" ] || fail "native PAM test binary not found"

valgrind \
    --error-exitcode=97 \
    --leak-check=full \
    --errors-for-leak-kinds=definite,indirect \
    --show-leak-kinds=definite,indirect \
    --track-origins=yes \
    "$test_bin" parse --test-threads=1
