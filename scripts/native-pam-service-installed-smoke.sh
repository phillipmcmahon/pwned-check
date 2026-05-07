#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="${PWNED_CHECK_TEST_PAM_SERVICE_NAME:-pwned-check-native-service-installed-smoke}"
. "$ROOT/scripts/lib/native-pam-smoke-common.sh"

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

[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM service-file installed smoke skipped: Linux host required"
    exit 0
}

require_command cc
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

MODULE_DIR="$(pkg-config --variable=securedir pam 2>/dev/null || true)"
if [ -r /etc/os-release ] && grep -Eq '^ID=alpine$' /etc/os-release; then
    if [ -f /usr/lib/security/pam_permit.so ]; then
        MODULE_DIR="/usr/lib/security"
    else
        MODULE_DIR="/lib/security"
    fi
fi
[ -n "$MODULE_DIR" ] || MODULE_DIR="/usr/lib/security"

CHECKER_PATH="/usr/bin/pwned-check"
MODULE_PATH="$MODULE_DIR/pam_pwned_check.so"
ENABLE_HELPER="/usr/share/pwned-check/service-pam/enable-service-pam.sh"
ROLLBACK_HELPER="/usr/share/pwned-check/service-pam/rollback-service-pam.sh"
ENABLE_DRY_RUN_HELPER="$(command -v pwned-check-pam-enable-dry-run || true)"
ENABLE_ENFORCE_HELPER="$(command -v pwned-check-pam-enable-enforce || true)"
DISABLE_HELPER="$(command -v pwned-check-pam-disable || true)"
SERVICE_FILE="/etc/pam.d/$SERVICE"
AUTHTOK_MODULE_PATH="$MODULE_DIR/pam_service_authtok.so"

[ -x "$CHECKER_PATH" ] || fail "checker is not installed at $CHECKER_PATH"
[ -f "$MODULE_PATH" ] || fail "module is not installed at $MODULE_PATH"
[ "$(stat -c '%a' "$MODULE_PATH")" = "644" ] || fail "PAM module should be installed mode 0644"
[ -x "$ENABLE_HELPER" ] || fail "service-file enable helper is not installed at $ENABLE_HELPER"
[ -x "$ROLLBACK_HELPER" ] || fail "service-file rollback helper is not installed at $ROLLBACK_HELPER"
[ -x "$ENABLE_DRY_RUN_HELPER" ] || fail "service-file dry-run wrapper is not installed at $ENABLE_DRY_RUN_HELPER"
[ -x "$ENABLE_ENFORCE_HELPER" ] || fail "service-file enforce wrapper is not installed at $ENABLE_ENFORCE_HELPER"
[ -x "$DISABLE_HELPER" ] || fail "service-file disable wrapper is not installed at $DISABLE_HELPER"

EXPECTED_HELPER_DIR="/usr/sbin"
if [ -r /etc/os-release ] && grep -Eq '^ID=arch$' /etc/os-release; then
    EXPECTED_HELPER_DIR="/usr/bin"
fi
for helper in "$ENABLE_DRY_RUN_HELPER" "$ENABLE_ENFORCE_HELPER" "$DISABLE_HELPER"; do
    canonical_helper="$helper"
    if command -v readlink >/dev/null 2>&1; then
        canonical_helper="$(readlink -f "$helper" 2>/dev/null || printf '%s\n' "$helper")"
    fi
    case "$helper" in
        "$EXPECTED_HELPER_DIR"/*) ;;
        *)
            case "$canonical_helper" in
                "$EXPECTED_HELPER_DIR"/*) ;;
                *) fail "service-file wrapper resolved outside expected helper directory $EXPECTED_HELPER_DIR: $helper" ;;
            esac
            ;;
    esac
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-service-installed.XXXXXX")"
STATE_FILE="$TMP/service-pam-last-backup"
BACKUP_DIR="$TMP/backups"

cleanup() {
    set +e
    as_root env \
        PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
        PWNED_CHECK_STATE_FILE="$STATE_FILE" \
        "$ROLLBACK_HELPER" >/dev/null 2>&1
    as_root rm -f "$SERVICE_FILE"
    as_root rm -f "$AUTHTOK_MODULE_PATH"
    as_root rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

write_native_pam_client_c "$TMP/native-pam-service-client.c"
write_native_pam_authtok_module_c "$TMP/pam_service_authtok.c" "PWNED_CHECK_TEST_PAM_TOKEN"

cc -Wall -Wextra -Werror -o "$TMP/native-pam-service-client" "$TMP/native-pam-service-client.c" -lpam
cc -Wall -Wextra -Werror -fPIC -shared -o "$TMP/pam_service_authtok.so" "$TMP/pam_service_authtok.c" -lpam
as_root install -m 0755 "$TMP/pam_service_authtok.so" "$AUTHTOK_MODULE_PATH"

CHECKER="$TMP/native-pam-service-checker"
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
password required pam_service_authtok.so
password required pam_permit.so
EOF
as_root install -d "$(dirname "$SERVICE_FILE")"
as_root install -m 0644 "$TMP/service" "$SERVICE_FILE"

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_BACKUP_DIR="$BACKUP_DIR" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    PWNED_CHECK_INSERT_AFTER_PATTERN="pam_service_authtok.so" \
    "$ENABLE_DRY_RUN_HELPER"
grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null || fail "dry-run wrapper did not add pam_pwned_check"
grep -F 'dry_run' "$SERVICE_FILE" >/dev/null || fail "dry-run wrapper did not enable dry_run"

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_BACKUP_DIR="$BACKUP_DIR" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    PWNED_CHECK_INSERT_AFTER_PATTERN="pam_service_authtok.so" \
    "$ENABLE_ENFORCE_HELPER"
grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null || fail "enforce wrapper removed pam_pwned_check"
grep -F 'fail_open' "$SERVICE_FILE" >/dev/null || fail "enforce wrapper missing fail_open"
if grep -F 'pam_pwned_check.so' "$SERVICE_FILE" | grep -F 'dry_run' >/dev/null; then
    cat "$SERVICE_FILE" >&2
    fail "enforce wrapper left dry_run configured"
fi

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_BACKUP_DIR="$BACKUP_DIR" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    PWNED_CHECK_INSERT_AFTER_PATTERN="pam_service_authtok.so" \
    "$ENABLE_ENFORCE_HELPER" --fail-closed
grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null || fail "fail-closed enforce wrapper removed pam_pwned_check"
grep -F 'fail_closed' "$SERVICE_FILE" >/dev/null || fail "fail-closed enforce wrapper missing fail_closed"
if grep -F 'pam_pwned_check.so' "$SERVICE_FILE" | grep -F 'fail_open' >/dev/null; then
    cat "$SERVICE_FILE" >&2
    fail "fail-closed enforce wrapper left fail_open configured"
fi

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    "$DISABLE_HELPER"
if grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null; then
    cat "$SERVICE_FILE" >&2
    fail "disable wrapper left pam_pwned_check configured"
fi

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_BACKUP_DIR="$BACKUP_DIR" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    PWNED_CHECK_MODULE_LINE="password requisite pam_pwned_check.so checker=$CHECKER timeout=1 fail_open" \
    PWNED_CHECK_INSERT_AFTER_PATTERN="pam_service_authtok.so" \
    "$ENABLE_HELPER"
grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null || fail "service helper did not add pam_pwned_check"

run_case() {
    name="$1"
    mode="$2"
    token="$3"
    want="$4"
    printf '%s' "$mode" >"$TMP/checker-mode"
    rm -f "$TMP/checker-argv" "$TMP/checker-token" "$TMP/case.out"
    set +e
    PWNED_CHECK_TEST_PAM_TOKEN="$token" "$TMP/native-pam-service-client" "$SERVICE" root "$token" >"$TMP/case.out" 2>&1
    rc="$?"
    set -e
    if [ "$want" = allow ] && [ "$rc" -ne 0 ]; then
        cat "$TMP/case.out" >&2
        fail "service-file installed smoke case failed: $name rc=$rc want allow"
    fi
    if [ "$want" = reject ] && [ "$rc" -eq 0 ]; then
        cat "$TMP/case.out" >&2
        fail "service-file installed smoke case failed: $name rc=$rc want reject"
    fi
    [ "$(cat "$TMP/checker-argv")" = "--stdin" ] || fail "service-file installed smoke case failed: $name checker argv mismatch"
    [ "$(cat "$TMP/checker-token")" = "$token" ] || fail "service-file installed smoke case failed: $name checker token mismatch"
    if grep -F "$token" "$TMP/case.out" >/dev/null; then
        cat "$TMP/case.out" >&2
        fail "service-file installed smoke case failed: $name leaked token to PAM output"
    fi
    echo "Native PAM service-file installed case passed: $name"
}

run_case "clean allowed" clean NativeServiceClean123 allow
run_case "pwned rejected" pwned NativeServicePwned123 reject

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    "$ROLLBACK_HELPER"
if grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null; then
    cat "$SERVICE_FILE" >&2
    fail "rollback left pam_pwned_check configured"
fi

trap - EXIT INT TERM
as_root rm -f "$SERVICE_FILE"
as_root rm -f "$AUTHTOK_MODULE_PATH"
as_root rm -rf "$TMP"
echo "Native PAM service-file installed smoke passed"
