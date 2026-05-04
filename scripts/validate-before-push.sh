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

NO_VM_DOCKER_IMAGES="${PWNED_CHECK_NO_VM_DOCKER_IMAGES:-archlinux:base-devel}"

unformatted="$(gofmt -l .)"
if [ -n "$unformatted" ]; then
    echo "Go files are not formatted. Run gofmt -w on these files:" >&2
    printf '%s\n' "$unformatted" >&2
    exit 1
fi

echo "make native-pam-fmt"
make native-pam-fmt

echo "go test -v -race ./..."
go test -v -race ./...

echo "make native-pam-test"
make native-pam-test

echo "make native-pam-memory-check"
make native-pam-memory-check

echo "make native-pam-build"
make native-pam-build

echo "make native-pam-symbols"
make native-pam-symbols

echo "make native-pam-deps"
make native-pam-deps

echo "make native-pam-harness"
make native-pam-harness

echo "make fuzz-smoke"
make fuzz-smoke

echo "make coverage"
make coverage

echo "go vet ./..."
go vet ./...

echo "go run honnef.co/go/tools/cmd/staticcheck ./..."
go run honnef.co/go/tools/cmd/staticcheck ./...

echo "make build"
make build

echo "make smoke"
make smoke

echo "make docker-smoke (no-VM targets: $NO_VM_DOCKER_IMAGES)"
DOCKER_SMOKE_IMAGES="$NO_VM_DOCKER_IMAGES" make docker-smoke

echo "make docker-pam-smoke (no-VM targets: $NO_VM_DOCKER_IMAGES)"
DOCKER_PAM_SMOKE_IMAGES="$NO_VM_DOCKER_IMAGES" make docker-pam-smoke

echo "make package-linux"
make package-linux

echo "local validation passed"
