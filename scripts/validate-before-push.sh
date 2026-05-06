#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: ./scripts/validate-before-push.sh

Run the local validation gate that mirrors the required CI checks.

Environment:
  PWNED_CHECK_VM_SMOKE_HOSTS       Space-separated VM host aliases to test
  PWNED_CHECK_NO_VM_DOCKER_IMAGES  Space-separated local Docker-only images
  PWNED_CHECK_ARM64_DOCKER_IMAGES  Space-separated arm64 Docker images to test
  PWNED_CHECK_SKIP_VM_SMOKE=1      Skip VM smoke for deliberate offline work
  PWNED_CHECK_RUN_ARM64_DOCKER=1   Run local arm64 Docker smoke even when arm64 VMs are configured
  PWNED_CHECK_SKIP_ARM64_DOCKER=1  Skip arm64 Docker smoke for deliberate offline work
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

NO_VM_DOCKER_IMAGES="${PWNED_CHECK_NO_VM_DOCKER_IMAGES:-}"
ARM64_DOCKER_IMAGES="${PWNED_CHECK_ARM64_DOCKER_IMAGES:-debian:stable-slim ubuntu:24.04 fedora:latest rockylinux/rockylinux:10.1 alpine:3.22}"
VM_SMOKE_HOSTS="${PWNED_CHECK_VM_SMOKE_HOSTS:-codex-vm-ubuntu codex-vm-debian codex-vm-ubuntu-arm64 codex-vm-debian-arm64 codex-vm-fedora codex-vm-fedora-arm64 codex-vm-rocky codex-vm-rocky-arm64 codex-vm-alpine codex-vm-alpine-arm64 codex-vm-arch}"
VM_PREBUILT_DIR="/tmp/pwned-check-vm-prebuilt"
VM_PREBUILT_BIN="$VM_PREBUILT_DIR/pwned-check"
VM_CHECKOUT="/home/codex/pwned-check"
VERSION="$(git describe --tags --dirty --always 2>/dev/null || printf 'dev')"
LDFLAGS_VALUE="-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION -X github.com/phillipmcmahon/pwned-check/internal/pamhelper.Version=$VERSION"
REMOVE_DEB_PACKAGE="if dpkg -s pwned-check-native-pam >/dev/null 2>&1; then if command -v pwned-check-pam-disable >/dev/null 2>&1; then sudo pwned-check-pam-disable || true; fi; sudo env DEBIAN_FRONTEND=noninteractive dpkg -r pwned-check-native-pam; fi"
REMOVE_RPM_PACKAGE="if rpm -q pwned-check-native-pam >/dev/null 2>&1; then if command -v pwned-check-pam-disable >/dev/null 2>&1; then sudo pwned-check-pam-disable || true; fi; sudo rpm -e pwned-check-native-pam; fi"
REMOVE_APK_PACKAGE="if apk info -e pwned-check-native-pam >/dev/null 2>&1; then if command -v pwned-check-pam-disable >/dev/null 2>&1; then sudo pwned-check-pam-disable || true; fi; sudo apk del pwned-check-native-pam; fi"
REMOVE_ARCH_PACKAGE="if pacman -Q pwned-check-native-pam >/dev/null 2>&1; then if command -v pwned-check-pam-disable >/dev/null 2>&1; then sudo pwned-check-pam-disable || true; fi; sudo pacman -Rns --noconfirm pwned-check-native-pam; fi"

vm_goarch() {
    case "$1" in
        codex-vm-ubuntu-arm64 | codex-vm-debian-arm64 | codex-vm-fedora-arm64 | codex-vm-rocky-arm64 | codex-vm-alpine-arm64)
            printf '%s\n' arm64
            ;;
        *)
            printf '%s\n' amd64
            ;;
    esac
}

host_list_has_arm64_vm() {
    for host in $VM_SMOKE_HOSTS; do
        case "$host" in
            codex-vm-ubuntu-arm64 | codex-vm-debian-arm64 | codex-vm-fedora-arm64 | codex-vm-rocky-arm64 | codex-vm-alpine-arm64)
                return 0
                ;;
        esac
    done
    return 1
}

build_vm_checker() {
    goarch="$1"
    bin="$VM_PREBUILT_DIR/pwned-check-$goarch"
    stamp="$VM_PREBUILT_DIR/pwned-check-$goarch.version"

    if [ -x "$bin" ] && [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$VERSION" ]; then
        return
    fi

    echo "build Linux/$goarch checker for VM smoke"
    mkdir -p "$VM_PREBUILT_DIR"
    CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" go build -trimpath \
        -ldflags "$LDFLAGS_VALUE" \
        -o "$bin" ./cmd/pwned-check
    printf '%s\n' "$VERSION" >"$stamp"
}

run_vm() {
    host="$1"
    shift
    echo "ssh $host $*"
    ssh -o BatchMode=yes "$host" "$@"
}

sync_vm_checkout() {
    host="$1"
    goarch="$2"
    prebuilt_bin="$VM_PREBUILT_DIR/pwned-check-$goarch"

    echo "sync checkout to $host:$VM_CHECKOUT"
    run_vm "$host" "mkdir -p '$VM_CHECKOUT' '$VM_PREBUILT_DIR'"
    rsync -az --delete \
        --exclude .git \
        --exclude .test-output \
        --exclude build \
        --exclude dist \
        --exclude target \
        ./ "$host:$VM_CHECKOUT/"
    scp "$prebuilt_bin" "$host:$VM_PREBUILT_BIN" >/dev/null
    run_vm "$host" "chmod 0755 '$VM_PREBUILT_BIN' && '$VM_PREBUILT_BIN' --version"
}

run_vm_smoke() {
    host="$1"
    goarch="$(vm_goarch "$host")"
    build_vm_checker "$goarch"

    case "$host" in
        codex-vm-ubuntu | codex-vm-ubuntu-arm64)
            sync_vm_checkout "$host" "$goarch"
            run_vm "$host" "cd '$VM_CHECKOUT' && export PATH=\"\$HOME/.cargo/bin:/usr/sbin:/sbin:\$PATH\" && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness && $REMOVE_DEB_PACKAGE && PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-ubuntu-deb-package-smoke"
            ;;
        codex-vm-debian | codex-vm-debian-arm64)
            sync_vm_checkout "$host" "$goarch"
            run_vm "$host" "cd '$VM_CHECKOUT' && export PATH=\"/usr/sbin:/sbin:\$PATH\" && make native-pam-test native-pam-build native-pam-deps native-pam-symbols native-pam-harness && $REMOVE_DEB_PACKAGE && PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-ubuntu-deb-package-smoke"
            ;;
        codex-vm-fedora | codex-vm-fedora-arm64)
            sync_vm_checkout "$host" "$goarch"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && $REMOVE_RPM_PACKAGE && PWNED_CHECK_FEDORA_RPM_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-fedora-rpm-package-smoke"
            ;;
        codex-vm-rocky | codex-vm-rocky-arm64)
            sync_vm_checkout "$host" "$goarch"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && $REMOVE_RPM_PACKAGE && PWNED_CHECK_FEDORA_RPM_SMOKE_PWNED_CHECK_BIN='$VM_PREBUILT_BIN' make native-pam-fedora-rpm-package-smoke"
            ;;
        codex-vm-alpine | codex-vm-alpine-arm64)
            sync_vm_checkout "$host" "$goarch"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && $REMOVE_APK_PACKAGE && apk_name=\"\$(./scripts/package-native-pam-alpine-package.sh --version 0.0.0 --pwned-check-bin '$VM_PREBUILT_BIN')\" && trap 'sudo apk del pwned-check-native-pam >/dev/null 2>&1 || true' EXIT INT TERM && sudo apk add --allow-untrusted \"dist/release/\$apk_name\" && ./scripts/native-pam-manual-installed-smoke.sh && sudo apk del pwned-check-native-pam && trap - EXIT INT TERM"
            ;;
        codex-vm-arch)
            sync_vm_checkout "$host" "$goarch"
            run_vm "$host" "cd '$VM_CHECKOUT' && make native-pam-test native-pam-build native-pam-deps native-pam-symbols && $REMOVE_ARCH_PACKAGE && pkg_name=\"\$(./scripts/package-native-pam-arch-package.sh --version 0.0.0 --pwned-check-bin '$VM_PREBUILT_BIN')\" && trap 'sudo pacman -Rns --noconfirm pwned-check-native-pam >/dev/null 2>&1 || true' EXIT INT TERM && sudo pacman -U --noconfirm \"dist/release/\$pkg_name\" && ./scripts/native-pam-manual-installed-smoke.sh && sudo pacman -Rns --noconfirm pwned-check-native-pam && trap - EXIT INT TERM"
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

    require_command ssh
    require_command scp
    require_command rsync
    require_command go
    mkdir -p "$VM_PREBUILT_DIR"

    for host in $VM_SMOKE_HOSTS; do
        echo "VM smoke: $host"
        run_vm_smoke "$host"
    done
}

run_arm64_docker_smoke_stage() {
    if [ "${PWNED_CHECK_SKIP_ARM64_DOCKER:-}" = "1" ]; then
        echo "arm64 Docker smoke skipped by PWNED_CHECK_SKIP_ARM64_DOCKER=1"
        return
    fi

    if host_list_has_arm64_vm && [ "${PWNED_CHECK_RUN_ARM64_DOCKER:-}" != "1" ]; then
        echo "arm64 Docker smoke skipped: arm64 VM smoke hosts are configured; set PWNED_CHECK_RUN_ARM64_DOCKER=1 for local CI-parity Docker coverage"
        return
    fi

    [ -n "$ARM64_DOCKER_IMAGES" ] || fail "PWNED_CHECK_ARM64_DOCKER_IMAGES must not be empty unless PWNED_CHECK_SKIP_ARM64_DOCKER=1 is set"
    require_command docker

    echo "make docker-smoke (local arm64 CI-parity targets: $ARM64_DOCKER_IMAGES)"
    DOCKER_SMOKE_IMAGES="$ARM64_DOCKER_IMAGES" DOCKER_SMOKE_PLATFORM=linux/arm64 make docker-smoke

    echo "make docker-pam-smoke (local arm64 CI-parity targets: $ARM64_DOCKER_IMAGES)"
    DOCKER_PAM_SMOKE_IMAGES="$ARM64_DOCKER_IMAGES" DOCKER_PAM_SMOKE_PLATFORM=linux/arm64 make docker-pam-smoke
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

if [ -n "$NO_VM_DOCKER_IMAGES" ]; then
    echo "make docker-smoke (no-VM targets: $NO_VM_DOCKER_IMAGES)"
    DOCKER_SMOKE_IMAGES="$NO_VM_DOCKER_IMAGES" make docker-smoke

    echo "make docker-pam-smoke (no-VM targets: $NO_VM_DOCKER_IMAGES)"
    DOCKER_PAM_SMOKE_IMAGES="$NO_VM_DOCKER_IMAGES" make docker-pam-smoke
else
    echo "no local Docker-only smoke targets configured"
fi

run_arm64_docker_smoke_stage

echo "make package-linux"
make package-linux

echo "local validation passed"
