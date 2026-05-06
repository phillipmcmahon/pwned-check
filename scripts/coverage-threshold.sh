#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
THRESHOLD="${COVERAGE_THRESHOLD:-85}"
PACKAGES="${COVERAGE_PACKAGES:-./internal/pwned}"

usage() {
    cat <<'EOF'
Usage: ./scripts/coverage-threshold.sh

Check per-package Go test coverage for product logic packages.

Environment:
  COVERAGE_THRESHOLD  Minimum package coverage percentage (default: 85)
  COVERAGE_PACKAGES   Space-separated package list (default: internal product packages)
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

command -v go >/dev/null 2>&1 || fail "go not found"

case "$THRESHOLD" in
    ''|*[!0-9.]*)
        fail "COVERAGE_THRESHOLD must be numeric"
        ;;
esac

cd "$ROOT"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-coverage.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

failed=0
for pkg in $PACKAGES; do
    safe_name="$(printf '%s' "$pkg" | tr -c '[:alnum:]' '_')"
    profile="$work_dir/$safe_name.cover"
    go test "$pkg" -covermode=count -coverprofile="$profile"
    coverage="$(go tool cover -func="$profile" | awk '/^total:/ { sub(/%/, "", $3); print $3 }')"
    [ -n "$coverage" ] || fail "could not read coverage for $pkg"
    printf '%s coverage: %s%% (minimum %s%%)\n' "$pkg" "$coverage" "$THRESHOLD"
    if ! awk -v got="$coverage" -v want="$THRESHOLD" 'BEGIN { exit(got + 0 >= want + 0 ? 0 : 1) }'; then
        failed=1
    fi
done

if [ "$failed" -ne 0 ]; then
    fail "coverage threshold not met"
fi

echo "coverage threshold passed"
