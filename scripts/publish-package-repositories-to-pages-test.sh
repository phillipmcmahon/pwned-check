#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/publish-package-repositories-to-pages.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_command git
require_command rsync

REMOTE="$TMP_DIR/remote.git"
INIT_REPO="$TMP_DIR/init"
SOURCE="$TMP_DIR/package-repositories"
WORKTREE="$TMP_DIR/pages-worktree"
VERIFY="$TMP_DIR/verify"

git init --bare "$REMOTE" >/dev/null
git init "$INIT_REPO" >/dev/null
git -C "$INIT_REPO" config user.name "Test"
git -C "$INIT_REPO" config user.email "test@example.invalid"
printf '%s\n' 'old content' > "$INIT_REPO/stale.txt"
mkdir -p "$INIT_REPO/apt"
printf '%s\n' 'old apt content' > "$INIT_REPO/apt/old.txt"
git -C "$INIT_REPO" add .
git -C "$INIT_REPO" commit -m "Initial pages content" >/dev/null
git -C "$INIT_REPO" branch -M gh-pages
git -C "$INIT_REPO" remote add origin "$REMOTE"
git -C "$INIT_REPO" push origin gh-pages >/dev/null

mkdir -p "$SOURCE/apt" "$SOURCE/rpm" "$SOURCE/alpine" "$SOURCE/arch"
printf '%s\n' 'new apt content' > "$SOURCE/apt/index.html"
printf '%s\n' 'new rpm content' > "$SOURCE/rpm/repomd.xml"
printf '%s\n' 'public key placeholder' > "$SOURCE/pwned-check-openpgp-production.asc"
printf '%s\n' 'BDF6F4DD343E9F10EA9DB510FDDA2848A95AD641' > "$SOURCE/pwned-check-openpgp-production.fingerprint.txt"

(
    cd "$INIT_REPO"
    "$SCRIPT" \
        --repository-dir "$SOURCE" \
        --worktree "$WORKTREE" \
        --remote origin \
        --branch gh-pages \
        --message "Publish test repository"
)

git clone --branch gh-pages "$REMOTE" "$VERIFY" >/dev/null 2>&1
[ -f "$VERIFY/apt/index.html" ] || fail "apt repository file was not published"
[ -f "$VERIFY/rpm/repomd.xml" ] || fail "rpm repository file was not published"
[ ! -e "$VERIFY/stale.txt" ] || fail "stale root file was not removed"
[ ! -e "$VERIFY/apt/old.txt" ] || fail "stale nested file was not removed"

before="$(git -C "$VERIFY" rev-parse HEAD)"
(
    cd "$INIT_REPO"
    "$SCRIPT" \
        --repository-dir "$SOURCE" \
        --worktree "$WORKTREE" \
        --remote origin \
        --branch gh-pages \
        --message "Publish test repository"
) >/dev/null
after="$(git --git-dir "$REMOTE" rev-parse gh-pages)"
[ "$before" = "$after" ] || fail "idempotent publish created an unexpected commit"

echo "package repository Pages publication tests passed"

