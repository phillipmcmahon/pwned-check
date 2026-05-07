#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/native-pam-repo-endpoint-check-retry.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
    echo "Error: $*" >&2
    exit 1
}

STUB="$TMP_DIR/stub-check.sh"
COUNTER="$TMP_DIR/counter"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
counter="$PWNED_CHECK_TEST_RETRY_COUNTER"
count=0
[ ! -f "$counter" ] || count="$(cat "$counter")"
count=$((count + 1))
printf '%s\n' "$count" > "$counter"
[ "$1" = "--base-url" ] || exit 20
[ "$2" = "https://example.invalid/repo" ] || exit 21
[ "$count" -ge 3 ]
EOF
chmod +x "$STUB"

PWNED_CHECK_REPO_ENDPOINT_CHECK_COMMAND="$STUB" \
PWNED_CHECK_TEST_RETRY_COUNTER="$COUNTER" \
    "$SCRIPT" --base-url https://example.invalid/repo --attempts 4 --delay 0 >/dev/null
[ "$(cat "$COUNTER")" = "3" ] || fail "expected success on third attempt"

ALWAYS_FAIL="$TMP_DIR/always-fail.sh"
cat > "$ALWAYS_FAIL" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$ALWAYS_FAIL"

if PWNED_CHECK_REPO_ENDPOINT_CHECK_COMMAND="$ALWAYS_FAIL" \
    "$SCRIPT" --base-url https://example.invalid/repo --attempts 2 --delay 0 >/dev/null 2>&1; then
    fail "expected retry wrapper to fail when all attempts fail"
fi

echo "repository endpoint retry tests passed"

