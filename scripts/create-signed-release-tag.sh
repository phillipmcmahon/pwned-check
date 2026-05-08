#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=scripts/lib/release-helpers.sh
. "$ROOT/scripts/lib/release-helpers.sh"

usage() {
    cat <<'EOF'
Usage: ./scripts/create-signed-release-tag.sh --version <vX.Y.Z> --notes <file> [OPTIONS]

Create and verify a signed annotated release tag from a release-notes file.

Options:
  --version <vX.Y.Z>  Release tag to create
  --notes <file>      Release notes file used as the annotated tag body
  --key-id <id>       GPG signing key id (default: PWNED_CHECK_RELEASE_SIGNING_KEY_ID or git config user.signingkey)
  --push              Push the tag to origin after local signature verification
  --remote <name>     Git remote used with --push (default: origin)
  --help              Show this help text

The script refuses dirty worktrees, duplicate local or remote tags, and release
notes that do not contain the headings required by the tag-triggered workflow.
EOF
}

VERSION=""
NOTES_FILE=""
KEY_ID="${PWNED_CHECK_RELEASE_SIGNING_KEY_ID:-}"
PUSH_TAG=0
REMOTE="origin"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --notes)
            [ "$#" -ge 2 ] || fail "--notes requires a value"
            NOTES_FILE="$2"
            shift 2
            ;;
        --key-id)
            [ "$#" -ge 2 ] || fail "--key-id requires a value"
            KEY_ID="$2"
            shift 2
            ;;
        --push)
            PUSH_TAG=1
            shift
            ;;
        --remote)
            [ "$#" -ge 2 ] || fail "--remote requires a value"
            REMOTE="$2"
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
[ -n "$NOTES_FILE" ] || fail "--notes is required"

case "$VERSION" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail "--version must be a release tag like v1.2.3" ;;
esac
case "${VERSION#v}" in
    *[!0-9.]* | .* | *..* | *.) fail "--version must be a dotted numeric release tag like v1.2.3" ;;
esac

[ -f "$NOTES_FILE" ] || fail "release notes file not found: $NOTES_FILE"
[ -s "$NOTES_FILE" ] || fail "release notes file is empty: $NOTES_FILE"

require_command git
require_command grep

if [ -z "$KEY_ID" ]; then
    KEY_ID="$(git -C "$ROOT" config --get user.signingkey || true)"
fi
[ -n "$KEY_ID" ] || fail "no signing key configured; pass --key-id or set PWNED_CHECK_RELEASE_SIGNING_KEY_ID"

for heading in "Highlights" "Operator impact" "Validation"; do
    if ! grep -E "^##[[:space:]]+${heading}$" "$NOTES_FILE" >/dev/null; then
        fail "release notes are missing required heading: ## $heading"
    fi
done

(
    cd "$ROOT"

    [ -z "$(git status --porcelain)" ] || fail "worktree is not clean"

    current_branch="$(git symbolic-ref --quiet --short HEAD || true)"
    [ "$current_branch" = "main" ] || fail "release tags must be created from main; current branch is ${current_branch:-detached}"

    git rev-parse --verify HEAD >/dev/null
    if git rev-parse --quiet --verify "refs/tags/$VERSION" >/dev/null; then
        fail "local tag already exists: $VERSION"
    fi
    if git ls-remote --exit-code --tags "$REMOTE" "refs/tags/$VERSION" >/dev/null 2>&1; then
        fail "remote tag already exists on $REMOTE: $VERSION"
    fi

    if git rev-parse --quiet --verify "$REMOTE/main" >/dev/null; then
        local_head="$(git rev-parse HEAD)"
        remote_head="$(git rev-parse "$REMOTE/main")"
        [ "$local_head" = "$remote_head" ] || fail "HEAD $local_head does not match $REMOTE/main $remote_head"
    fi

    git tag -s -u "$KEY_ID" "$VERSION" --cleanup=verbatim -F "$NOTES_FILE"
    git tag -v "$VERSION" >/dev/null

    echo "Created and verified signed tag $VERSION"

    if [ "$PUSH_TAG" -eq 1 ]; then
        git push "$REMOTE" "$VERSION"
        echo "Pushed signed tag $VERSION to $REMOTE"
    else
        echo "Tag not pushed. Push with: git push $REMOTE $VERSION"
    fi
)
