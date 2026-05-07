#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE_VERSION="${NATIVE_PAM_UBUNTU_DEB_SMOKE_VERSION:-0.0.0+ubuntu.deb.smoke}"
PACKAGE_NAME="pwned-check-native-pam"
PWNED_CHECK_BIN="${PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN:-}"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-ubuntu-deb-package-smoke.sh

Build the native PAM .deb package, install it through dpkg, exercise the
installed files with the Ubuntu host package smoke, enable and disable the
PAM profile through the packaged mode helpers, remove the package, and verify
cleanup.

Environment:
  NATIVE_PAM_UBUNTU_DEB_SMOKE_VERSION    Version label for the .deb package
  PWNED_CHECK_UBUNTU_DEB_SMOKE_PWNED_CHECK_BIN
                                           Existing Linux pwned-check binary
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM Ubuntu .deb package smoke skipped: Linux host required"
    exit 0
}

if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) fail ".deb package smoke currently supports Debian/Ubuntu hosts only, got ID=${OS_ID:-unknown}" ;;
    esac
fi

require_command dpkg
require_command dpkg-deb
require_command gcc
require_command make
require_command pam-auth-update
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi
[ -z "$PWNED_CHECK_BIN" ] || [ -x "$PWNED_CHECK_BIN" ] || fail "prebuilt pwned-check binary is not executable: $PWNED_CHECK_BIN"

MULTIARCH="$(gcc -print-multiarch)"
[ -n "$MULTIARCH" ] || fail "could not determine GCC multiarch tuple"
MODULE_PATH="/lib/$MULTIARCH/security/pam_pwned_check.so"
CHECKER_PATH="/usr/bin/pwned-check"
PROFILE_PATH="/usr/share/pam-configs/pwned-check"
MODE_HELPER_DIR="/usr/share/pwned-check/debian-pam"
ENABLE_DRY_RUN_HELPER="/usr/sbin/pwned-check-pam-enable-dry-run"
ENABLE_ENFORCE_HELPER="/usr/sbin/pwned-check-pam-enable-enforce"
DISABLE_HELPER="/usr/sbin/pwned-check-pam-disable"
COMMON_PASSWORD="/etc/pam.d/common-password"

if dpkg -s "$PACKAGE_NAME" >/dev/null 2>&1; then
    fail "$PACKAGE_NAME is already installed; remove it before running the smoke"
fi

for path in "$CHECKER_PATH" "$MODULE_PATH" "$PROFILE_PATH" "$MODE_HELPER_DIR" "$ENABLE_DRY_RUN_HELPER" "$ENABLE_ENFORCE_HELPER" "$DISABLE_HELPER"; do
    [ ! -e "$path" ] || fail "refusing to overwrite existing host install path: $path"
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-deb-smoke.XXXXXX")"
COMMON_PASSWORD_BACKUP="$TMP/common-password.before"
as_root cp "$COMMON_PASSWORD" "$COMMON_PASSWORD_BACKUP"

INSTALLED=""
cleanup() {
    set +e
    if [ -n "$INSTALLED" ]; then
        as_root env DEBIAN_FRONTEND=noninteractive pam-auth-update --disable pwned-check --package >/dev/null 2>&1
        as_root dpkg -r "$PACKAGE_NAME" >/dev/null 2>&1
    fi
    if ! cmp -s "$COMMON_PASSWORD" "$COMMON_PASSWORD_BACKUP"; then
        as_root cp "$COMMON_PASSWORD_BACKUP" "$COMMON_PASSWORD"
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
if [ -n "$PWNED_CHECK_BIN" ]; then
    deb_name="$(./scripts/package-native-pam-debian-package.sh --version "$SMOKE_VERSION" --pwned-check-bin "$PWNED_CHECK_BIN")"
else
    deb_name="$(./scripts/package-native-pam-debian-package.sh --version "$SMOKE_VERSION")"
fi
deb_path="$ROOT/dist/release/$deb_name"
[ -f "$deb_path" ] || fail ".deb package was not produced: $deb_path"

as_root dpkg -i "$deb_path"
INSTALLED=1

dpkg -s "$PACKAGE_NAME" >/dev/null
dpkg -L "$PACKAGE_NAME" | grep -F "$MODULE_PATH" >/dev/null || fail "package file list missing PAM module"
[ -f "$MODULE_PATH" ] || fail "PAM module missing after package install"
[ "$(stat -c '%a' "$MODULE_PATH")" = "644" ] || fail "PAM module should be installed mode 0644"
dpkg -L "$PACKAGE_NAME" | grep -F "$CHECKER_PATH" >/dev/null || fail "package file list missing checker"
dpkg -L "$PACKAGE_NAME" | grep -F "$PROFILE_PATH" >/dev/null || fail "package file list missing pam-auth-update profile"
dpkg -L "$PACKAGE_NAME" | grep -F "$ENABLE_DRY_RUN_HELPER" >/dev/null || fail "package file list missing dry-run helper"
dpkg -L "$PACKAGE_NAME" | grep -F "$ENABLE_ENFORCE_HELPER" >/dev/null || fail "package file list missing enforce helper"
dpkg -L "$PACKAGE_NAME" | grep -F "$DISABLE_HELPER" >/dev/null || fail "package file list missing disable helper"

./scripts/native-pam-ubuntu-host-package-smoke.sh

as_root "$ENABLE_DRY_RUN_HELPER"
grep -F 'pam_pwned_check.so' "$COMMON_PASSWORD" >/dev/null || fail "dry-run helper did not update common-password"
grep -F 'dry_run' "$PROFILE_PATH" >/dev/null || fail "dry-run helper did not keep dry_run in profile"
grep -F 'dry_run' "$COMMON_PASSWORD" >/dev/null || fail "dry-run helper enabled line missing dry_run"

as_root "$ENABLE_ENFORCE_HELPER"
grep -F 'pam_pwned_check.so' "$COMMON_PASSWORD" >/dev/null || fail "enforce helper removed pam_pwned_check from common-password"
grep -F 'fail_open' "$PROFILE_PATH" >/dev/null || fail "enforce helper profile missing fail_open"
if grep -F 'dry_run' "$PROFILE_PATH" >/dev/null; then
    fail "enforce helper left dry_run in profile"
fi
if grep -F 'pam_pwned_check.so' "$COMMON_PASSWORD" | grep -F 'dry_run' >/dev/null; then
    fail "enforce helper left dry_run in common-password"
fi

as_root "$ENABLE_ENFORCE_HELPER" --fail-closed
grep -F 'pam_pwned_check.so' "$COMMON_PASSWORD" >/dev/null || fail "fail-closed enforce helper removed pam_pwned_check from common-password"
grep -F 'fail_closed' "$PROFILE_PATH" >/dev/null || fail "fail-closed enforce helper profile missing fail_closed"
if grep -F 'fail_open' "$PROFILE_PATH" >/dev/null; then
    fail "fail-closed enforce helper left fail_open in profile"
fi
if grep -F 'pam_pwned_check.so' "$COMMON_PASSWORD" | grep -F 'fail_closed' >/dev/null; then
    :
else
    fail "fail-closed enforce helper common-password line missing fail_closed"
fi

as_root "$DISABLE_HELPER"
if grep -F 'pam_pwned_check.so' "$COMMON_PASSWORD" >/dev/null; then
    fail "disable helper left pam_pwned_check in common-password"
fi
cmp -s "$COMMON_PASSWORD" "$COMMON_PASSWORD_BACKUP" || fail "common-password was not restored after helper disable"

as_root dpkg -r "$PACKAGE_NAME"
INSTALLED=""

dpkg -s "$PACKAGE_NAME" >/dev/null 2>&1 && fail "$PACKAGE_NAME is still installed after removal"
for path in "$CHECKER_PATH" "$MODULE_PATH" "$PROFILE_PATH" "$MODE_HELPER_DIR" "$ENABLE_DRY_RUN_HELPER" "$ENABLE_ENFORCE_HELPER" "$DISABLE_HELPER"; do
    [ ! -e "$path" ] || fail "package-managed path still exists after removal: $path"
done
cmp -s "$COMMON_PASSWORD" "$COMMON_PASSWORD_BACKUP" || fail "common-password changed after package removal"

trap - EXIT INT TERM
rm -rf "$TMP"
echo "Native PAM Ubuntu .deb package smoke passed: $deb_name"
