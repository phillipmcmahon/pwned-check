#!/bin/sh

set -eu

OWNER_REPO="${PWNED_CHECK_GITHUB_REPO:-phillipmcmahon/pwned-check}"
BRANCH="${PWNED_CHECK_GITHUB_BRANCH:-main}"
WORKFLOW="${PWNED_CHECK_GITHUB_CI_WORKFLOW:-ci.yml}"
SHA="${PWNED_CHECK_GITHUB_SHA:-}"
POLL_SECONDS="${PWNED_CHECK_GITHUB_POLL_SECONDS:-5}"
WAIT_SECONDS="${PWNED_CHECK_GITHUB_WAIT_SECONDS:-300}"

usage() {
    cat <<'EOF'
Usage: ./scripts/github-ci-watch.sh

Wait for the GitHub CI workflow run for a pushed commit, then stream it to
completion with `gh run watch --exit-status`.

Environment:
  PWNED_CHECK_GITHUB_REPO          owner/repo (default: phillipmcmahon/pwned-check)
  PWNED_CHECK_GITHUB_BRANCH        branch to check (default: main)
  PWNED_CHECK_GITHUB_CI_WORKFLOW   workflow file name (default: ci.yml)
  PWNED_CHECK_GITHUB_SHA           commit SHA to watch (default: local HEAD)
  PWNED_CHECK_GITHUB_WAIT_SECONDS  max seconds to wait for run creation (default: 300)
  PWNED_CHECK_GITHUB_POLL_SECONDS  polling interval while waiting (default: 5)
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

require_command gh
require_command git
require_command jq

case "$POLL_SECONDS" in
    ''|*[!0-9]*) fail "PWNED_CHECK_GITHUB_POLL_SECONDS must be an integer" ;;
esac
case "$WAIT_SECONDS" in
    ''|*[!0-9]*) fail "PWNED_CHECK_GITHUB_WAIT_SECONDS must be an integer" ;;
esac
[ "$POLL_SECONDS" -gt 0 ] || fail "PWNED_CHECK_GITHUB_POLL_SECONDS must be greater than zero"

if [ -z "$SHA" ]; then
    SHA="$(git rev-parse HEAD)"
fi

elapsed=0
run_json=""

echo "Waiting for GitHub CI workflow '$WORKFLOW' on $BRANCH at $SHA"

while [ "$elapsed" -le "$WAIT_SECONDS" ]; do
    run_json="$(gh run list \
        --repo "$OWNER_REPO" \
        --workflow "$WORKFLOW" \
        --branch "$BRANCH" \
        --commit "$SHA" \
        --limit 1 \
        --json databaseId,status,conclusion,url \
        | jq '.[0] // empty')"

    if [ -n "$run_json" ]; then
        break
    fi

    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
done

[ -n "$run_json" ] || fail "no GitHub CI run found for $SHA after ${WAIT_SECONDS}s"

run_id="$(printf '%s' "$run_json" | jq -r '.databaseId')"
run_url="$(printf '%s' "$run_json" | jq -r '.url')"

echo "Watching GitHub CI run $run_id"
echo "  $run_url"

gh run watch "$run_id" --repo "$OWNER_REPO" --exit-status
