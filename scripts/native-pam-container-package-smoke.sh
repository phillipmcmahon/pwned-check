#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DISTRO="${NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_DISTRO:-}"
PLATFORM="${NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_PLATFORM:-linux/amd64}"
IMAGE="${NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_IMAGE:-}"
SMOKE_VERSION="${NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_VERSION:-}"
EXPORT_DIR="${NATIVE_PAM_CONTAINER_PACKAGE_SMOKE_EXPORT_DIR:-}"
WORKDIR="/workspace/pwned-check"
PREBUILT_CHECKER=""

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-container-package-smoke.sh --distro <arch|alpine> [OPTIONS]

Build a native PAM package in the matching distro container, install it with
the distro package manager, exercise installed service-file wrapper behavior,
remove the package, and verify managed-file cleanup.

This is CI/fallback coverage. Local package acceptance uses persistent VMs when
a matching VM exists.

Options:
  --distro <distro>      Distro package family: arch or alpine
  --platform <platform>  Docker platform
  --image <image>        Docker image override
  --help                 Show this help text
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
        --distro)
            [ "$#" -ge 2 ] || fail "--distro requires a value"
            DISTRO="$2"
            shift 2
            ;;
        --platform)
            [ "$#" -ge 2 ] || fail "--platform requires a value"
            PLATFORM="$2"
            shift 2
            ;;
        --image)
            [ "$#" -ge 2 ] || fail "--image requires a value"
            IMAGE="$2"
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

[ -n "$DISTRO" ] || fail "--distro is required"
case "$DISTRO" in
    arch)
        case "$PLATFORM" in linux/amd64) ;; *) fail "Arch package smoke supports linux/amd64 only: $PLATFORM" ;; esac
        IMAGE="${IMAGE:-archlinux:base-devel}"
        SMOKE_VERSION="${SMOKE_VERSION:-arch-package-smoke}"
        ;;
    alpine)
        case "$PLATFORM" in linux/amd64|linux/arm64|linux/arm64/v8) ;; *) fail "Alpine package smoke does not support platform: $PLATFORM" ;; esac
        IMAGE="${IMAGE:-alpine:3.22}"
        SMOKE_VERSION="${SMOKE_VERSION:-0.0.0}"
        ;;
    *)
        fail "unsupported container package smoke distro: $DISTRO"
        ;;
esac

require_command docker

go_arch_for_platform() {
    case "$1" in
        linux/amd64) printf '%s\n' amd64 ;;
        linux/arm64|linux/arm64/v8) printf '%s\n' arm64 ;;
        *) fail "unsupported checker build platform: $1" ;;
    esac
}

build_package_checker() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-$DISTRO-checker.XXXXXX")"
    PREBUILT_CHECKER="$tmp/pwned-check"
    goarch="$(go_arch_for_platform "$PLATFORM")"
    (
        cd "$ROOT"
        if [ "$goarch" = "amd64" ]; then
            CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64="${GOAMD64:-v1}" \
                go build -trimpath \
                -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$SMOKE_VERSION" \
                -o "$PREBUILT_CHECKER" ./cmd/pwned-check
        else
            CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
                go build -trimpath \
                -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$SMOKE_VERSION" \
                -o "$PREBUILT_CHECKER" ./cmd/pwned-check
        fi
    )
}

sync_repo() {
    cid="$1"
    docker exec "$cid" sh -lc "rm -rf '$WORKDIR' && mkdir -p '$WORKDIR'"
    if [ "$(uname -s)" = "Darwin" ]; then
        TAR_XATTR_FLAGS="--no-xattrs"
    elif tar --help 2>/dev/null | grep -q -- '--no-xattrs'; then
        TAR_XATTR_FLAGS="--no-xattrs"
    else
        TAR_XATTR_FLAGS=""
    fi
    COPYFILE_DISABLE=1 tar $TAR_XATTR_FLAGS \
        --exclude=.git \
        --exclude=.test-output \
        --exclude=build \
        --exclude=dist \
        --exclude=target \
        -C "$ROOT" \
        -cf - . \
        | docker exec -i "$cid" tar -C "$WORKDIR" -xf -
}

cleanup_prebuilt() {
    if [ -n "$PREBUILT_CHECKER" ]; then
        rm -rf "$(dirname "$PREBUILT_CHECKER")"
    fi
}

run_arch() {
    cid="$1"
    docker exec "$cid" sh -lc "
        set -eu
        if [ -f /etc/pacman.conf ]; then
          sed -i 's/^DownloadUser[[:space:]]*=/#DownloadUser =/' /etc/pacman.conf
        fi
        pacman -Sy --noconfirm --needed base-devel ca-certificates file gcc make pam pkgconf rust tar zstd
        cd '$WORKDIR'
        echo '::group::[build:arch] packaging'
        pkg_name=\"\$(./scripts/package-native-pam-arch-package.sh --version '$SMOKE_VERSION' --pwned-check-bin /tmp/native-pam-package-pwned-check)\"
        pkg_path=\"dist/release/\$pkg_name\"
        test -f \"\$pkg_path\"
        echo '::endgroup::'
        echo '::group::[smoke:arch] validating'
        pacman -U --noconfirm \"\$pkg_path\"
        pacman -Q pwned-check-native-pam >/dev/null
        pacman -Ql pwned-check-native-pam | grep -F '/usr/lib/security/pam_pwned_check.so' >/dev/null
        pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check' >/dev/null
        pacman -Ql pwned-check-native-pam | grep -F '/usr/share/pwned-check/service-pam/enable-service-pam.sh' >/dev/null
        pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check-pam-enable-dry-run' >/dev/null
        pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check-pam-enable-enforce' >/dev/null
        pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check-pam-disable' >/dev/null
        ./scripts/native-pam-service-installed-smoke.sh
        pacman -R --noconfirm pwned-check-native-pam
        if pacman -Q pwned-check-native-pam >/dev/null 2>&1; then
          echo 'Arch package still installed after removal' >&2
          exit 1
        fi
        for path in /usr/bin/pwned-check /usr/bin/pwned-check-pam-enable-dry-run /usr/bin/pwned-check-pam-enable-enforce /usr/bin/pwned-check-pam-disable /usr/lib/security/pam_pwned_check.so /usr/share/pwned-check/service-pam; do
          if [ -e \"\$path\" ]; then
            echo \"Arch package-managed path still exists after removal: \$path\" >&2
            exit 1
          fi
        done
        echo \"Native PAM Arch package smoke passed: \$pkg_name\"
        echo '::endgroup::'
    "
}

run_alpine() {
    cid="$1"
    docker exec "$cid" sh -lc "
        set -eu
        apk add --no-cache alpine-sdk ca-certificates cargo file gcc linux-pam linux-pam-dev make musl-dev openssl pkgconf rust sudo tar
        cd '$WORKDIR'
        echo '::group::[build:alpine] packaging'
        apk_name=\"\$(./scripts/package-native-pam-alpine-package.sh --version '$SMOKE_VERSION' --pwned-check-bin /tmp/native-pam-package-pwned-check)\"
        apk_path=\"dist/release/\$apk_name\"
        test -f \"\$apk_path\"
        echo '::endgroup::'
        echo '::group::[smoke:alpine] validating'
        apk add --allow-untrusted \"\$apk_path\"
        apk info -e pwned-check-native-pam >/dev/null
        apk info -L pwned-check-native-pam | grep -F 'usr/lib/security/pam_pwned_check.so' >/dev/null
        apk info -L pwned-check-native-pam | grep -F 'usr/bin/pwned-check' >/dev/null
        apk info -L pwned-check-native-pam | grep -F 'usr/share/pwned-check/service-pam/enable-service-pam.sh' >/dev/null
        apk info -L pwned-check-native-pam | grep -F 'usr/sbin/pwned-check-pam-enable-dry-run' >/dev/null
        apk info -L pwned-check-native-pam | grep -F 'usr/sbin/pwned-check-pam-enable-enforce' >/dev/null
        apk info -L pwned-check-native-pam | grep -F 'usr/sbin/pwned-check-pam-disable' >/dev/null
        ./scripts/native-pam-service-installed-smoke.sh
        apk del pwned-check-native-pam
        if apk info -e pwned-check-native-pam >/dev/null 2>&1; then
          echo 'Alpine package still installed after removal' >&2
          exit 1
        fi
        for path in /usr/bin/pwned-check /usr/sbin/pwned-check-pam-enable-dry-run /usr/sbin/pwned-check-pam-enable-enforce /usr/sbin/pwned-check-pam-disable /usr/lib/security/pam_pwned_check.so /usr/share/pwned-check/service-pam; do
          if [ -e \"\$path\" ]; then
            echo \"Alpine package-managed path still exists after removal: \$path\" >&2
            exit 1
          fi
        done
        echo \"Native PAM Alpine package smoke passed: \$apk_name\"
        echo '::endgroup::'
    "
}

trap cleanup_prebuilt EXIT INT TERM
build_package_checker

echo "Native PAM $DISTRO package smoke: $IMAGE ($PLATFORM)"
cid="$(docker create --platform "$PLATFORM" "$IMAGE" sleep infinity)"
cleanup_container() {
    docker rm -f "$cid" >/dev/null 2>&1 || true
    cleanup_prebuilt
}
trap cleanup_container EXIT INT TERM
docker start "$cid" >/dev/null
sync_repo "$cid"
docker cp "$PREBUILT_CHECKER" "$cid:/tmp/native-pam-package-pwned-check"

case "$DISTRO" in
    arch) run_arch "$cid" ;;
    alpine) run_alpine "$cid" ;;
esac

if [ -n "$EXPORT_DIR" ]; then
    mkdir -p "$EXPORT_DIR"
    docker cp "$cid:$WORKDIR/dist/release/." "$EXPORT_DIR/"
fi

docker rm -f "$cid" >/dev/null
trap - EXIT INT TERM
cleanup_prebuilt
echo "Native PAM $DISTRO package smoke passed"
