#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="pwned-check-native-fedora-host-package-smoke"
PROFILE_NAME="${PWNED_CHECK_FEDORA_HOST_SMOKE_PROFILE:-pwned-check-smoke}"
STATE_DIR="${PWNED_CHECK_FEDORA_HOST_SMOKE_STATE_DIR:-/var/lib/pwned-check-smoke}"
. "$ROOT/scripts/lib/native-pam-smoke-common.sh"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-fedora-host-package-smoke.sh

Exercise the already installed RPM-family native PAM package files through a
disposable PAM service and packaged authselect helpers. This is an internal
helper for the RPM package smoke.

The authselect helper inserts the module in dry-run mode. This smoke uses a
dedicated custom authselect profile name and restores the authselect backup
before exiting.

Environment:
  PWNED_CHECK_FEDORA_HOST_SMOKE_PROFILE     Custom authselect profile name
  PWNED_CHECK_FEDORA_HOST_SMOKE_STATE_DIR   State directory for authselect backup name
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

if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM Fedora host package smoke skipped: Linux host required"
    exit 0
}

if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    OS_ID_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')"
    case " $OS_ID $OS_ID_LIKE " in
        *" fedora "*|*" rhel "*|*" centos "*) ;;
        *) fail "host package smoke currently supports Fedora/RHEL-family hosts only, got ID=${OS_ID:-unknown}" ;;
    esac
fi

require_command authselect
require_command cc
require_command make
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

MODULE_PATH="/lib64/security/pam_pwned_check.so"
CHECKER_PATH="/usr/bin/pwned-check"
AUTHSELECT_DIR="/usr/share/pwned-check/authselect"
ENABLE_DRY_RUN_HELPER="/usr/sbin/pwned-check-pam-enable-dry-run"
ENABLE_ENFORCE_HELPER="/usr/sbin/pwned-check-pam-enable-enforce"
DISABLE_HELPER="/usr/sbin/pwned-check-pam-disable"
SERVICE_FILE="/etc/pam.d/$SERVICE"
CUSTOM_PROFILE="/etc/authselect/custom/$PROFILE_NAME"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-fedora-host-package.XXXXXX")"

AUTHSELECT_ENABLED=""
CUSTOM_PROFILE_PREEXISTED=""
[ ! -e "$CUSTOM_PROFILE" ] || CUSTOM_PROFILE_PREEXISTED=1

cleanup() {
    set +e
    as_root rm -f "$SERVICE_FILE"
    if [ -n "$AUTHSELECT_ENABLED" ] && [ -x "$AUTHSELECT_DIR/rollback-authselect.sh" ]; then
        as_root env PWNED_CHECK_STATE_DIR="$STATE_DIR" "$AUTHSELECT_DIR/rollback-authselect.sh" >/dev/null 2>&1
    fi
    if [ -z "$CUSTOM_PROFILE_PREEXISTED" ]; then
        as_root rm -rf "$CUSTOM_PROFILE"
    fi
    as_root rm -rf "$STATE_DIR"
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

[ -x "$CHECKER_PATH" ] || fail "checker was not installed at $CHECKER_PATH"
[ -f "$MODULE_PATH" ] || fail "module was not installed at $MODULE_PATH"
[ "$(stat -c '%a' "$MODULE_PATH")" = "644" ] || fail "PAM module should be installed mode 0644"
[ -x "$AUTHSELECT_DIR/enable-authselect.sh" ] || fail "authselect enable helper was not installed"
[ -x "$AUTHSELECT_DIR/rollback-authselect.sh" ] || fail "authselect rollback helper was not installed"
[ -x "$ENABLE_DRY_RUN_HELPER" ] || fail "authselect dry-run wrapper was not installed"
[ -x "$ENABLE_ENFORCE_HELPER" ] || fail "authselect enforce wrapper was not installed"
[ -x "$DISABLE_HELPER" ] || fail "authselect disable wrapper was not installed"
"$CHECKER_PATH" --version >/dev/null

write_native_pam_client_c "$TMP/native-pam-fedora-host-client.c"
write_native_pam_authtok_module_c "$TMP/pam_fedora_host_authtok.c" "PWNED_CHECK_TEST_FEDORA_HOST_TOKEN"

cc -Wall -Wextra -Werror -o "$TMP/native-pam-fedora-host-client" "$TMP/native-pam-fedora-host-client.c" -lpam
cc -Wall -Wextra -Werror -fPIC -shared -o "$TMP/pam_fedora_host_authtok.so" "$TMP/pam_fedora_host_authtok.c" -lpam

CHECKER="$TMP/native-pam-fedora-host-checker"
cat > "$CHECKER" <<EOF
#!/bin/sh
set -eu
printf '%s' "\$*" >"$TMP/checker-argv"
token="\$(cat)"
printf '%s' "\$token" >"$TMP/checker-token"
case "\$(cat "$TMP/checker-mode")" in
  clean) exit 0 ;;
  pwned) exit 1 ;;
  *) exit 9 ;;
esac
EOF
chmod 0755 "$CHECKER"

cat > "$TMP/service" <<EOF
password required $TMP/pam_fedora_host_authtok.so
password requisite pam_pwned_check.so checker=$CHECKER timeout=1 fail_open
password required pam_permit.so
EOF
as_root install -m 0644 "$TMP/service" "$SERVICE_FILE"

run_case() {
    name="$1"
    mode="$2"
    token="$3"
    want="$4"
    printf '%s' "$mode" >"$TMP/checker-mode"
    rm -f "$TMP/checker-argv" "$TMP/checker-token" "$TMP/case.out"
    set +e
    PWNED_CHECK_TEST_FEDORA_HOST_TOKEN="$token" "$TMP/native-pam-fedora-host-client" "$SERVICE" root "$token" >"$TMP/case.out" 2>&1
    rc="$?"
    set -e
    if [ "$want" = allow ] && [ "$rc" -ne 0 ]; then
        cat "$TMP/case.out" >&2
        fail "Fedora host package smoke case failed: $name rc=$rc want allow"
    fi
    if [ "$want" = reject ] && [ "$rc" -eq 0 ]; then
        cat "$TMP/case.out" >&2
        fail "Fedora host package smoke case failed: $name rc=$rc want reject"
    fi
    [ "$(cat "$TMP/checker-argv")" = "--stdin" ] || fail "Fedora host package smoke case failed: $name checker argv mismatch"
    [ "$(cat "$TMP/checker-token")" = "$token" ] || fail "Fedora host package smoke case failed: $name checker token mismatch"
    if grep -F "$token" "$TMP/case.out" >/dev/null; then
        cat "$TMP/case.out" >&2
        fail "Fedora host package smoke case failed: $name leaked token to PAM output"
    fi
    echo "Native PAM Fedora host package case passed: $name"
}

run_case "clean allowed" clean FedoraHostPackageClean123 allow
run_case "pwned rejected" pwned FedoraHostPackagePwned123 reject

as_root env \
    PWNED_CHECK_AUTHSELECT_PROFILE="$PROFILE_NAME" \
    PWNED_CHECK_STATE_DIR="$STATE_DIR" \
    "$ENABLE_DRY_RUN_HELPER"
AUTHSELECT_ENABLED=1

authselect current -r | grep -F "custom/$PROFILE_NAME" >/dev/null || fail "authselect did not select custom/$PROFILE_NAME"
for stack in system-auth password-auth; do
    grep -F 'pam_pwned_check.so' "/etc/authselect/custom/$PROFILE_NAME/$stack" >/dev/null || fail "custom profile missing pam_pwned_check.so in $stack"
    grep -F 'dry_run' "/etc/authselect/custom/$PROFILE_NAME/$stack" >/dev/null || fail "custom profile missing dry_run in $stack"
    grep -F 'pam_pwned_check.so' "/etc/pam.d/$stack" >/dev/null || fail "active PAM stack missing pam_pwned_check.so in $stack"
done

as_root env \
    PWNED_CHECK_AUTHSELECT_PROFILE="$PROFILE_NAME" \
    PWNED_CHECK_STATE_DIR="$STATE_DIR" \
    "$ENABLE_ENFORCE_HELPER"
authselect current -r | grep -F "custom/$PROFILE_NAME" >/dev/null || fail "authselect did not keep custom/$PROFILE_NAME selected"
for stack in system-auth password-auth; do
    grep -F 'pam_pwned_check.so' "/etc/authselect/custom/$PROFILE_NAME/$stack" >/dev/null || fail "custom profile missing pam_pwned_check.so after enforce in $stack"
    if grep -F 'pam_pwned_check.so' "/etc/authselect/custom/$PROFILE_NAME/$stack" | grep -F 'dry_run' >/dev/null; then
        cat "/etc/authselect/custom/$PROFILE_NAME/$stack" >&2
        fail "enforce wrapper left dry_run in custom profile $stack"
    fi
    if grep -F 'pam_pwned_check.so' "/etc/pam.d/$stack" | grep -F 'dry_run' >/dev/null; then
        cat "/etc/pam.d/$stack" >&2
        fail "enforce wrapper left dry_run in active PAM stack $stack"
    fi
done

as_root env \
    PWNED_CHECK_AUTHSELECT_PROFILE="$PROFILE_NAME" \
    PWNED_CHECK_STATE_DIR="$STATE_DIR" \
    "$ENABLE_ENFORCE_HELPER" --fail-closed
for stack in system-auth password-auth; do
    line="$(grep -F 'pam_pwned_check.so' "/etc/authselect/custom/$PROFILE_NAME/$stack" || true)"
    [ -n "$line" ] || fail "custom profile missing pam_pwned_check.so after fail-closed enforce in $stack"
    printf '%s\n' "$line" | grep -F 'fail_closed' >/dev/null || fail "fail-closed enforce wrapper missing fail_closed in $stack"
    if printf '%s\n' "$line" | grep -F 'fail_open' >/dev/null; then
        cat "/etc/authselect/custom/$PROFILE_NAME/$stack" >&2
        fail "fail-closed enforce wrapper left fail_open in custom profile $stack"
    fi
done

as_root env PWNED_CHECK_STATE_DIR="$STATE_DIR" "$DISABLE_HELPER"
AUTHSELECT_ENABLED=""
authselect current -r | grep -F "custom/$PROFILE_NAME" >/dev/null && fail "authselect still selects custom/$PROFILE_NAME after rollback"
if grep -F 'pam_pwned_check.so' /etc/pam.d/system-auth /etc/pam.d/password-auth >/dev/null 2>&1; then
    fail "active authselect PAM stack still references pam_pwned_check after rollback"
fi

as_root rm -f "$SERVICE_FILE"
if [ -z "$CUSTOM_PROFILE_PREEXISTED" ]; then
    as_root rm -rf "$CUSTOM_PROFILE"
fi
as_root rm -rf "$STATE_DIR"

[ ! -e "$SERVICE_FILE" ] || fail "disposable PAM service still exists after rollback"

trap - EXIT INT TERM
rm -rf "$TMP"
echo "Native PAM Fedora host package smoke passed"
