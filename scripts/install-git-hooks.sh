#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
HOOKS_DIR="$ROOT/.git/hooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "Error: .git/hooks not found" >&2
    exit 1
fi

install -m 0755 "$ROOT/scripts/pre-push" "$HOOKS_DIR/pre-push"

echo "Installed pre-push hook -> .git/hooks/pre-push"
