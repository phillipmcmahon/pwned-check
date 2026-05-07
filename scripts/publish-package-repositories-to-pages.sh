#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check-no-private-signing-material.sh"
REPOSITORY_DIR=""
WORKTREE_DIR=""
REMOTE="origin"
BRANCH="gh-pages"
MESSAGE="Publish package repositories"

usage() {
    cat <<'EOF'
Usage: scripts/publish-package-repositories-to-pages.sh [OPTIONS]

Publish a generated package-repositories tree to a GitHub Pages branch.

Options:
  --repository-dir <path>  Generated package-repositories directory to publish
  --worktree <path>        Temporary git worktree path for the Pages branch
  --remote <name-or-url>   Git remote to push to (default: origin)
  --branch <name>          Pages branch to update (default: gh-pages)
  --message <message>      Commit message (default: Publish package repositories)
  --help                   Show this help text
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --repository-dir)
            [ "$#" -ge 2 ] || fail "--repository-dir requires a value"
            REPOSITORY_DIR="$2"
            shift 2
            ;;
        --worktree)
            [ "$#" -ge 2 ] || fail "--worktree requires a value"
            WORKTREE_DIR="$2"
            shift 2
            ;;
        --remote)
            [ "$#" -ge 2 ] || fail "--remote requires a value"
            REMOTE="$2"
            shift 2
            ;;
        --branch)
            [ "$#" -ge 2 ] || fail "--branch requires a value"
            BRANCH="$2"
            shift 2
            ;;
        --message)
            [ "$#" -ge 2 ] || fail "--message requires a value"
            MESSAGE="$2"
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

[ -n "$REPOSITORY_DIR" ] || fail "--repository-dir is required"
[ -n "$WORKTREE_DIR" ] || fail "--worktree is required"
[ -d "$REPOSITORY_DIR" ] || fail "repository directory does not exist: $REPOSITORY_DIR"
[ -x "$GUARD" ] || fail "private signing material guard is not executable: $GUARD"

require_command git
require_command rsync

"$GUARD" "$REPOSITORY_DIR"

if [ -e "$WORKTREE_DIR" ]; then
    [ -d "$WORKTREE_DIR" ] || fail "worktree path exists but is not a directory: $WORKTREE_DIR"
    rm -rf "$WORKTREE_DIR"
fi

git fetch "$REMOTE" "$BRANCH"
git worktree add "$WORKTREE_DIR" FETCH_HEAD

cleanup() {
    git worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT INT TERM

rsync -a --delete \
    --exclude .git \
    "$REPOSITORY_DIR/" \
    "$WORKTREE_DIR/"

"$GUARD" "$WORKTREE_DIR"

git -C "$WORKTREE_DIR" add -A
if git -C "$WORKTREE_DIR" diff --cached --quiet; then
    echo "Package repository Pages tree is already up to date"
    exit 0
fi

git -C "$WORKTREE_DIR" config user.name "${GIT_AUTHOR_NAME:-github-actions[bot]}"
git -C "$WORKTREE_DIR" config user.email "${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
git -C "$WORKTREE_DIR" commit -m "$MESSAGE"
git -C "$WORKTREE_DIR" push "$REMOTE" "HEAD:$BRANCH"

