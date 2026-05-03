#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${NATIVE_PAM_ARCH_PACKAGE_SMOKE_PLATFORM:-linux/amd64}"
IMAGE="${NATIVE_PAM_ARCH_PACKAGE_SMOKE_IMAGE:-archlinux:base-devel}"
SMOKE_VERSION="${NATIVE_PAM_ARCH_PACKAGE_SMOKE_VERSION:-arch-package-smoke}"
EXPORT_DIR="${NATIVE_PAM_ARCH_PACKAGE_SMOKE_EXPORT_DIR:-}"
WORKDIR="/workspace/pwned-check"
PREBUILT_CHECKER=""

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-arch-package-smoke.sh [OPTIONS]

Build the Arch native PAM package in an Arch container, install it with pacman,
exercise installed files through the manual PAM helper, remove the package, and
verify managed-file cleanup.

Options:
  --platform <platform>   Docker platform, currently linux/amd64
  --image <image>         Arch Docker image (default: archlinux:base-devel)
  --help                  Show this help text
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

case "$PLATFORM" in
    linux/amd64) ;;
    *) fail "unsupported platform for native PAM Arch package smoke: $PLATFORM" ;;
esac

require_command docker

build_package_checker() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-arch-checker.XXXXXX")"
    PREBUILT_CHECKER="$tmp/pwned-check"
    (
        cd "$ROOT"
        CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOAMD64="${GOAMD64:-v1}" \
            go build -trimpath \
            -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$SMOKE_VERSION" \
            -o "$PREBUILT_CHECKER" ./cmd/pwned-check
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
trap cleanup_prebuilt EXIT INT TERM
build_package_checker

echo "Native PAM Arch package smoke: $IMAGE ($PLATFORM)"
cid="$(docker create --platform "$PLATFORM" "$IMAGE" sleep infinity)"
cleanup_container() {
    docker rm -f "$cid" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT INT TERM
docker start "$cid" >/dev/null
sync_repo "$cid"
docker cp "$PREBUILT_CHECKER" "$cid:/tmp/native-pam-arch-pwned-check"

docker exec "$cid" sh -lc "
    set -eu
    if [ -f /etc/pacman.conf ]; then
      sed -i 's/^DownloadUser[[:space:]]*=/#DownloadUser =/' /etc/pacman.conf
    fi
    pacman -Sy --noconfirm --needed base-devel ca-certificates file gcc make pam pkgconf rust tar zstd
    cd '$WORKDIR'
    echo '::group::[build:arch] packaging'
    pkg_name=\"\$(./scripts/package-native-pam-arch-package.sh --version '$SMOKE_VERSION' --pwned-check-bin /tmp/native-pam-arch-pwned-check)\"
    pkg_path=\"dist/release/\$pkg_name\"
    test -f \"\$pkg_path\"
    echo '::endgroup::'
    echo '::group::[smoke:arch] validating'
    pacman -U --noconfirm \"\$pkg_path\"
    pacman -Q pwned-check-native-pam >/dev/null
    pacman -Ql pwned-check-native-pam | grep -F '/usr/lib/security/pam_pwned_check.so' >/dev/null
    pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check' >/dev/null
    pacman -Ql pwned-check-native-pam | grep -F '/usr/share/pwned-check/manual-pam/enable-manual-pam.sh' >/dev/null
    pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check-pam-enable-dry-run' >/dev/null
    pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check-pam-enable-enforce' >/dev/null
    pacman -Ql pwned-check-native-pam | grep -F '/usr/bin/pwned-check-pam-disable' >/dev/null
    ./scripts/native-pam-manual-installed-smoke.sh
    pacman -R --noconfirm pwned-check-native-pam
    if pacman -Q pwned-check-native-pam >/dev/null 2>&1; then
      echo 'Arch package still installed after removal' >&2
      exit 1
    fi
    for path in /usr/bin/pwned-check /usr/bin/pwned-check-pam-enable-dry-run /usr/bin/pwned-check-pam-enable-enforce /usr/bin/pwned-check-pam-disable /usr/lib/security/pam_pwned_check.so /usr/share/pwned-check/manual-pam; do
      if [ -e \"\$path\" ]; then
        echo \"Arch package-managed path still exists after removal: \$path\" >&2
        exit 1
      fi
    done
    echo \"Native PAM Arch package smoke passed: \$pkg_name\"
    echo '::endgroup::'
"

if [ -n "$EXPORT_DIR" ]; then
    mkdir -p "$EXPORT_DIR"
    docker cp "$cid:$WORKDIR/dist/release/." "$EXPORT_DIR/"
fi

docker rm -f "$cid" >/dev/null
trap - EXIT INT TERM
cleanup_prebuilt
echo "Native PAM Arch package smoke matrix passed"
