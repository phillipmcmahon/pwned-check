#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./scripts/validate-before-push.sh

Run the local validation gate that mirrors the required CI checks.
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

cd "$ROOT"

unformatted="$(gofmt -l .)"
if [ -n "$unformatted" ]; then
    echo "Go files are not formatted. Run gofmt -w on these files:" >&2
    printf '%s\n' "$unformatted" >&2
    exit 1
fi

echo "go test ./..."
go test ./...

echo "go vet ./..."
go vet ./...

echo "go run honnef.co/go/tools/cmd/staticcheck ./..."
go run honnef.co/go/tools/cmd/staticcheck ./...

echo "go build -o dist/pwned-check ./cmd/pwned-check"
go build -o dist/pwned-check ./cmd/pwned-check

echo "go run ./scripts/smoke_binary.go dist/pwned-check"
go run ./scripts/smoke_binary.go dist/pwned-check

echo "local validation passed"
