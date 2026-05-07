#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CHECK_COMMAND="${PWNED_CHECK_REPO_ENDPOINT_CHECK_COMMAND:-$ROOT/scripts/native-pam-repo-endpoint-check.sh}"
BASE_URL="${PWNED_CHECK_REPO_BASE_URL:-https://phillipmcmahon.github.io/pwned-check}"
ATTEMPTS=24
DELAY_SECONDS=10

usage() {
    cat <<'EOF'
Usage: scripts/native-pam-repo-endpoint-check-retry.sh [OPTIONS]

Run the native PAM repository endpoint check with bounded retries for GitHub
Pages propagation after a release workflow publishes the repository tree.

Options:
  --base-url <url>   Repository root
  --attempts <n>     Maximum attempts (default: 24)
  --delay <seconds>  Delay between attempts (default: 10)
  --help             Show this help text

Environment:
  PWNED_CHECK_REPO_ENDPOINT_CHECK_COMMAND  Override check command for tests
  PWNED_CHECK_REPO_BASE_URL                Default repository root
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

is_positive_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
        *) return 0 ;;
    esac
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base-url)
            [ "$#" -ge 2 ] || fail "--base-url requires a value"
            BASE_URL="${2%/}"
            shift 2
            ;;
        --attempts)
            [ "$#" -ge 2 ] || fail "--attempts requires a value"
            ATTEMPTS="$2"
            shift 2
            ;;
        --delay)
            [ "$#" -ge 2 ] || fail "--delay requires a value"
            DELAY_SECONDS="$2"
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

is_positive_integer "$ATTEMPTS" || fail "--attempts must be a positive integer"
case "$DELAY_SECONDS" in
    ''|*[!0-9]*) fail "--delay must be a non-negative integer" ;;
esac

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    echo "Repository endpoint validation attempt $attempt/$ATTEMPTS"
    if "$CHECK_COMMAND" --base-url "$BASE_URL"; then
        echo "Repository endpoint validation passed"
        exit 0
    fi

    if [ "$attempt" -eq "$ATTEMPTS" ]; then
        break
    fi

    echo "Repository endpoint validation did not pass yet; retrying in ${DELAY_SECONDS}s"
    sleep "$DELAY_SECONDS"
    attempt=$((attempt + 1))
done

fail "repository endpoint validation failed after $ATTEMPTS attempts"

