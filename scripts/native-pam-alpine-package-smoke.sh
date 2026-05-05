#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${NATIVE_PAM_ALPINE_PACKAGE_SMOKE_PLATFORM:-linux/amd64}"
IMAGE="${NATIVE_PAM_ALPINE_PACKAGE_SMOKE_IMAGE:-alpine:3.22}"
SMOKE_VERSION="${NATIVE_PAM_ALPINE_PACKAGE_SMOKE_VERSION:-0.0.0}"
EXPORT_DIR="${NATIVE_PAM_ALPINE_PACKAGE_SMOKE_EXPORT_DIR:-}"
WORKDIR="/workspace/pwned-check"
PREBUILT_CHECKER=""

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-alpine-package-smoke.sh [OPTIONS]

Build the Alpine native PAM package in an Alpine Linux-PAM container, install it
with apk, exercise installed files through the manual PAM helper, remove the
package, and verify managed-file cleanup.

Options:
  --platform <platform>   Docker platform: linux/amd64 or linux/arm64
  --image <image>         Alpine Docker image (default: alpine:3.22)
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
    linux/amd64|linux/arm64|linux/arm64/v8) ;;
    *) fail "unsupported platform for native PAM Alpine package smoke: $PLATFORM" ;;
esac

require_command docker

build_package_checker() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-alpine-checker.XXXXXX")"
    PREBUILT_CHECKER="$tmp/pwned-check"
    case "$PLATFORM" in
        linux/amd64)
            goarch=amd64
            goamd64="${GOAMD64:-v1}"
            ;;
        linux/arm64|linux/arm64/v8)
            goarch=arm64
            goamd64=""
            ;;
        *)
            fail "unsupported checker build platform: $PLATFORM"
            ;;
    esac
    (
        cd "$ROOT"
        if [ "$goarch" = "amd64" ]; then
            CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOAMD64="$goamd64" \
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
trap cleanup_prebuilt EXIT INT TERM
build_package_checker

echo "Native PAM Alpine package smoke: $IMAGE ($PLATFORM)"
cid="$(docker create --platform "$PLATFORM" "$IMAGE" sleep infinity)"
cleanup_container() {
    docker rm -f "$cid" >/dev/null 2>&1 || true
}
trap cleanup_container EXIT INT TERM
docker start "$cid" >/dev/null
sync_repo "$cid"
docker cp "$PREBUILT_CHECKER" "$cid:/tmp/native-pam-alpine-pwned-check"

docker exec "$cid" sh -lc "
    set -eu
    apk add --no-cache alpine-sdk ca-certificates cargo file gcc linux-pam linux-pam-dev make musl-dev openssl pkgconf rust sudo tar
    cd '$WORKDIR'
    echo '::group::[build:alpine] packaging'
    apk_name=\"\$(./scripts/package-native-pam-alpine-package.sh --version '$SMOKE_VERSION' --pwned-check-bin /tmp/native-pam-alpine-pwned-check)\"
    apk_path=\"dist/release/\$apk_name\"
    test -f \"\$apk_path\"
    echo '::endgroup::'
    echo '::group::[smoke:alpine] validating'
    apk add --allow-untrusted \"\$apk_path\"
    apk info -e pwned-check-native-pam >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'usr/lib/security/pam_pwned_check.so' >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'lib/security/pam_pwned_check.so' >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'usr/bin/pwned-check' >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'usr/share/pwned-check/manual-pam/enable-manual-pam.sh' >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'usr/sbin/pwned-check-pam-enable-dry-run' >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'usr/sbin/pwned-check-pam-enable-enforce' >/dev/null
    apk info -L pwned-check-native-pam | grep -F 'usr/sbin/pwned-check-pam-disable' >/dev/null
    ./scripts/native-pam-manual-installed-smoke.sh
    apk del pwned-check-native-pam
    if apk info -e pwned-check-native-pam >/dev/null 2>&1; then
      echo 'Alpine package still installed after removal' >&2
      exit 1
    fi
    for path in /usr/bin/pwned-check /usr/lib/security/pam_pwned_check.so /lib/security/pam_pwned_check.so /usr/share/pwned-check/manual-pam; do
      if [ -e \"\$path\" ]; then
        echo \"Alpine package-managed path still exists after removal: \$path\" >&2
        exit 1
      fi
    done
    echo \"Native PAM Alpine package smoke passed: \$apk_name\"
    echo '::endgroup::'
"

if [ -n "$EXPORT_DIR" ]; then
    mkdir -p "$EXPORT_DIR"
    docker cp "$cid:$WORKDIR/dist/release/." "$EXPORT_DIR/"
fi

docker rm -f "$cid" >/dev/null
trap - EXIT INT TERM
cleanup_prebuilt
echo "Native PAM Alpine package smoke matrix passed"
