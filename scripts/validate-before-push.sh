#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./scripts/validate-before-push.sh

Run the local validation gate that mirrors the required CI checks.

Environment:
  PWNED_CHECK_VM_SMOKE_HOSTS       Space-separated VM host aliases to test
  PWNED_CHECK_SKIP_VM_SMOKE=1      Skip VM smoke for deliberate offline work
  PWNED_CHECK_VM_SMOKE_ONLY=1      Run only the VM smoke stage
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

cd "$ROOT"

NO_VM_DOCKER_IMAGES="${PWNED_CHECK_NO_VM_DOCKER_IMAGES:-archlinux:base-devel}"
VM_SMOKE_HOSTS="${PWNED_CHECK_VM_SMOKE_HOSTS:-codex-vm-ubuntu codex-vm-debian codex-vm-fedora codex-vm-rocky codex-vm-alpine}"
VM_PREBUILT_DIR="/tmp/pwned-check-vm-prebuilt"
VM_PREBUILT_BIN="$VM_PREBUILT_DIR/pwned-check"
VM_CHECKOUT="/home/codex/pwned-check"
VERSION="$(git describe --tags --dirty --always 2>/dev/null || printf 'dev')"
LDFLAGS_VALUE="-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION -X github.com/phillipmcmahon/pwned-check/internal/pamhelper.Version=$VERSION"

run_vm() {
    host="$1"
    shift
    echo "ssh $host $*"
    ssh -o BatchMode=yes "$host" "$@"
}

sync_vm_checkout() {
    host="$1"
    echo "sync checkout to $host:$VM_CHECKOUT"
    run_vm "$host" "mkdir -p '$VM_CHECKOUT' '$VM_PREBUILT_DIR'"
    rsync -az --delete \
        --exclude .git \
        --exclude .test-output \
        --exclude build \
        --exclude dist \
        --exclude target \
        ./ "$host:$VM_CHECKOUT/"
    scp "$VM_PREBUILT_BIN" "$host:$VM_PREBUILT_BIN" >/dev/null
    run_vm "$host" "chmod 0755 '$VM_PREBUILT_BIN' && '$VM_PREBUILT_BIN' --version"
}

run_vm_smoke() {
    host="$1"
    case "$host" in
        codex-vm-ubuntu)
            sync_vm_checkout "$host"
            run_vm "$host" "cd '$VM_CHECKOUT' && PATH=\"\$HOME/.cargo/bin:\$PATH\" make native-pam-test native-pam-build native-pam-deps native-pam-symbols && if dpkg -s pwned-check-native-pam >/dev/null 2>&1; then PWNED_CHECK_UBUNTU_HOST_SMOKE_USE_INSTALLED=1 make native-pam-ubuntu-host-package-smoke; else PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-ubuntu-deb-package-smoke; fi"
            ;;
        codex-vm-debian)
            sync_vm_checkout "$host"
            run_vm "$host" "cd '$VM_CHECKOUT' && export PATH=\"/usr/sbin:/sbin:\$PATH\" && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness && if dpkg -s pwned-check-native-pam >/dev/null 2>&1; then PWNED_CHECK_UBUNTU_HOST_SMOKE_USE_INSTALLED=1 make native-pam-ubuntu-host-package-smoke; else PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-ubuntu-deb-package-smoke; fi"
            ;;
        codex-vm-fedora)
            sync_vm_checkout "$host"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && if rpm -q pwned-check-native-pam >/dev/null 2>&1; then PWNED_CHECK_FEDORA_HOST_SMOKE_USE_INSTALLED=1 make native-pam-fedora-host-package-smoke; else PWNED_CHECK_FEDORA_RPM_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-fedora-rpm-package-smoke; fi"
            ;;
        codex-vm-rocky)
            sync_vm_checkout "$host"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && if rpm -q pwned-check-native-pam >/dev/null 2>&1; then PWNED_CHECK_FEDORA_HOST_SMOKE_USE_INSTALLED=1 make native-pam-fedora-host-package-smoke; else PWNED_CHECK_FEDORA_RPM_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-fedora-rpm-package-smoke; fi"
            ;;
        codex-vm-alpine)
            sync_vm_checkout "$host"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && if apk info -e pwned-check-native-pam >/dev/null 2>&1; then ./scripts/native-pam-manual-installed-smoke.sh; else apk_name=\"\$(./scripts/package-native-pam-alpine-package.sh --version 0.0.0 --pwned-check-bin '$VM_PREBUILT_BIN')\" && trap 'sudo apk del pwned-check-native-pam >/dev/null 2>&1 || true' EXIT INT TERM && sudo apk add --allow-untrusted \"dist/release/\$apk_name\" && ./scripts/native-pam-manual-installed-smoke.sh && sudo apk del pwned-check-native-pam && trap - EXIT INT TERM; fi"
            ;;
        *)
            fail "unknown VM smoke host: $host"
            ;;
    esac
}

run_vm_smoke_stage() {
    if [ "${PWNED_CHECK_SKIP_VM_SMOKE:-}" = "1" ]; then
        echo "VM smoke skipped by PWNED_CHECK_SKIP_VM_SMOKE=1"
        return
    fi

    echo "build Linux checker for VM smoke"
    require_command ssh
    require_command scp
    require_command rsync
    mkdir -p "$VM_PREBUILT_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath \
        -ldflags "$LDFLAGS_VALUE" \
        -o "$VM_PREBUILT_BIN" ./cmd/pwned-check

    for host in $VM_SMOKE_HOSTS; do
        echo "VM smoke: $host"
        run_vm_smoke "$host"
    done
}

if [ "${PWNED_CHECK_VM_SMOKE_ONLY:-}" = "1" ]; then
    run_vm_smoke_stage
    echo "VM smoke validation passed"
    exit 0
fi

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

run_vm_smoke_stage

echo "make docker-smoke (no-VM targets: $NO_VM_DOCKER_IMAGES)"
DOCKER_SMOKE_IMAGES="$NO_VM_DOCKER_IMAGES" make docker-smoke

echo "make docker-pam-smoke (no-VM targets: $NO_VM_DOCKER_IMAGES)"
DOCKER_PAM_SMOKE_IMAGES="$NO_VM_DOCKER_IMAGES" make docker-pam-smoke

echo "make package-linux"
make package-linux

echo "local validation passed"
