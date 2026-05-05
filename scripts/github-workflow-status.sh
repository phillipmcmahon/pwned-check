#!/bin/sh

set -eu

OWNER_REPO="${PWNED_CHECK_GITHUB_REPO:-phillipmcmahon/pwned-check}"
BRANCH="${PWNED_CHECK_GITHUB_BRANCH:-main}"
WORKFLOWS="${PWNED_CHECK_GITHUB_WORKFLOWS:-ci.yml native-pam-packages.yml fuzz.yml}"

usage() {
    cat <<'EOF'
Usage: ./scripts/github-workflow-status.sh

Check the latest completed GitHub Actions run for each required workflow on a
branch. This is intended for release readiness checks that need to catch
scheduled workflow failures as well as tag or push workflow failures.

Environment:
  PWNED_CHECK_GITHUB_REPO       owner/repo (default: phillipmcmahon/pwned-check)
  PWNED_CHECK_GITHUB_BRANCH     branch to check (default: main)
  PWNED_CHECK_GITHUB_WORKFLOWS  workflow file names to check
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
require_command jq

failures=0

for workflow in $WORKFLOWS; do
    run_json="$(gh run list \
        --repo "$OWNER_REPO" \
        --workflow "$workflow" \
        --branch "$BRANCH" \
        --status completed \
        --limit 1 \
        --json conclusion,databaseId,event,headSha,url \
        | jq '.[0] // empty')"

    if [ -z "$run_json" ]; then
        echo "GitHub workflow status: $workflow has no completed runs on $BRANCH" >&2
        failures=$((failures + 1))
        continue
    fi

    conclusion="$(printf '%s' "$run_json" | jq -r '.conclusion')"
    database_id="$(printf '%s' "$run_json" | jq -r '.databaseId')"
    event="$(printf '%s' "$run_json" | jq -r '.event')"
    url="$(printf '%s' "$run_json" | jq -r '.url')"
    head_sha="$(printf '%s' "$run_json" | jq -r '.headSha')"

    echo "GitHub workflow status: $workflow run $database_id ($event, $head_sha) -> $conclusion"
    echo "  $url"

    if [ "$conclusion" != "success" ]; then
        failures=$((failures + 1))
    fi
done

[ "$failures" -eq 0 ] || fail "$failures required GitHub workflow(s) are not green"

echo "GitHub workflow status passed"
