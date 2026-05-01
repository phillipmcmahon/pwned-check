#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SMOKE_VERSION="${NATIVE_PAM_FEDORA_RPM_SMOKE_VERSION:-fedora-rpm-smoke}"
PACKAGE_NAME="pwned-check-native-pam"
PROFILE_NAME="${PWNED_CHECK_FEDORA_RPM_SMOKE_PROFILE:-pwned-check-rpm-smoke}"
STATE_DIR="${PWNED_CHECK_FEDORA_RPM_SMOKE_STATE_DIR:-/var/lib/pwned-check-rpm-smoke}"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-fedora-rpm-package-smoke.sh

Build the native PAM RPM package, install it through RPM-family package tooling,
exercise the installed files with the Fedora host package smoke, and remove the
package while verifying the managed files are gone.

Environment:
  NATIVE_PAM_FEDORA_RPM_SMOKE_VERSION    Version label for the RPM package
  PWNED_CHECK_FEDORA_RPM_SMOKE_PROFILE   Custom authselect profile name
  PWNED_CHECK_FEDORA_RPM_SMOKE_STATE_DIR State directory for authselect backup name
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
    echo "native PAM Fedora RPM package smoke skipped: Linux host required"
    exit 0
}

if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    OS_ID_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')"
    case " $OS_ID $OS_ID_LIKE " in
        *" fedora "*|*" rhel "*|*" centos "*) ;;
        *) fail "RPM package smoke currently supports Fedora/RHEL-family hosts only, got ID=${OS_ID:-unknown}" ;;
    esac
fi

require_command rpm
require_command rpmbuild
require_command make
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    fail "$PACKAGE_NAME is already installed; remove it before running the smoke"
fi

for path in /usr/bin/pwned-check /lib64/security/pam_pwned_check.so /usr/share/pwned-check/authselect; do
    [ ! -e "$path" ] || fail "refusing to overwrite existing host install path: $path"
done

INSTALLED=""
cleanup() {
    set +e
    if [ -n "$INSTALLED" ]; then
        as_root rpm -e "$PACKAGE_NAME" >/dev/null 2>&1
    fi
    as_root rm -rf "$STATE_DIR"
}
trap cleanup EXIT INT TERM

cd "$ROOT"
rpm_name="$(./scripts/package-native-pam-rpm-package.sh --version "$SMOKE_VERSION")"
rpm_path="$ROOT/dist/release/$rpm_name"
[ -f "$rpm_path" ] || fail "RPM package was not produced: $rpm_path"

if command -v dnf >/dev/null 2>&1; then
    as_root dnf install -y "$rpm_path"
else
    as_root rpm -Uvh "$rpm_path"
fi
INSTALLED=1

rpm -q "$PACKAGE_NAME" >/dev/null
rpm -ql "$PACKAGE_NAME" | grep -F '/lib64/security/pam_pwned_check.so' >/dev/null || fail "RPM file list missing PAM module"
rpm -ql "$PACKAGE_NAME" | grep -F '/usr/bin/pwned-check' >/dev/null || fail "RPM file list missing checker"
rpm -ql "$PACKAGE_NAME" | grep -F '/usr/share/pwned-check/authselect/enable-authselect.sh' >/dev/null || fail "RPM file list missing authselect enable helper"

PWNED_CHECK_FEDORA_HOST_SMOKE_USE_INSTALLED=1 \
PWNED_CHECK_FEDORA_HOST_SMOKE_PROFILE="$PROFILE_NAME" \
PWNED_CHECK_FEDORA_HOST_SMOKE_STATE_DIR="$STATE_DIR" \
    ./scripts/native-pam-fedora-host-package-smoke.sh

as_root rpm -e "$PACKAGE_NAME"
INSTALLED=""

rpm -q "$PACKAGE_NAME" >/dev/null 2>&1 && fail "$PACKAGE_NAME is still installed after removal"
for path in /usr/bin/pwned-check /lib64/security/pam_pwned_check.so /usr/share/pwned-check/authselect; do
    [ ! -e "$path" ] || fail "RPM managed path still exists after removal: $path"
done

trap - EXIT INT TERM
echo "Native PAM Fedora RPM package smoke passed: $rpm_name"
