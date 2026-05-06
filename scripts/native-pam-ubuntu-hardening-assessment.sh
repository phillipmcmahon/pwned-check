#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-ubuntu-hardening-assessment}"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
RUN_DIR="$OUTPUT_ROOT/${STAMP}-native-pam-ubuntu-hardening-assessment"
COMBINED="$RUN_DIR/native-pam-ubuntu-hardening-assessment.txt"
SMOKE_LOG="$RUN_DIR/ubuntu-deb-package-smoke.txt"
APPARMOR_LOG="$RUN_DIR/apparmor-after-smoke.txt"
SERVICE="pwned-check-native-lockout-drill"
SERVICE_FILE="/etc/pam.d/$SERVICE"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-ubuntu-hardening-assessment.sh

Run the Ubuntu/Debian native PAM .deb package smoke, capture AppArmor state,
and prove a deliberately broken disposable PAM service can be restored.

The lockout drill does not modify common-password. It uses a temporary PAM
service under /etc/pam.d and removes it during cleanup.

Environment:
  PWNED_CHECK_TEST_OUTPUT_DIR                 Override output root
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

append_section() {
    title="$1"
    {
        printf '\n## %s\n\n' "$title"
        cat
    } >>"$COMBINED"
}

run_capture() {
    title="$1"
    shift
    {
        printf '$'
        for arg in "$@"; do
            printf ' %s' "$arg"
        done
        printf '\n'
        "$@" 2>&1 || true
    } | append_section "$title"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM Ubuntu hardening assessment skipped: Linux host required"
    exit 0
}

if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) fail "hardening assessment currently supports Debian/Ubuntu hosts only, got ID=${OS_ID:-unknown}" ;;
    esac
fi

require_command cc
require_command make
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

mkdir -p "$RUN_DIR"
ln -sfn "$(basename "$RUN_DIR")" "$OUTPUT_ROOT/latest"

START_JOURNAL="$(date '+%Y-%m-%d %H:%M:%S')"

{
    printf '# Native PAM Ubuntu Hardening Assessment\n\n'
    printf 'Started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Repository: %s\n' "$ROOT"
    printf 'Output directory: %s\n' "$RUN_DIR"
} >"$COMBINED"

run_capture "OS Release" cat /etc/os-release
run_capture "Kernel" uname -a

if [ -r /sys/module/apparmor/parameters/enabled ]; then
    run_capture "AppArmor kernel state" cat /sys/module/apparmor/parameters/enabled
else
    printf '\n## AppArmor kernel state\n\n/sys/module/apparmor/parameters/enabled is not readable\n' >>"$COMBINED"
fi
if command -v aa-status >/dev/null 2>&1; then
    run_capture "AppArmor status before smoke" as_root aa-status
else
    printf '\n## AppArmor status before smoke\n\naa-status not installed\n' >>"$COMBINED"
fi
if [ -r /sys/kernel/security/apparmor/profiles ]; then
    run_capture "AppArmor profiles before smoke" as_root cat /sys/kernel/security/apparmor/profiles
fi

set +e
(
    cd "$ROOT"
    make native-pam-ubuntu-deb-package-smoke
) >"$SMOKE_LOG" 2>&1
SMOKE_RC="$?"
set -e
cat "$SMOKE_LOG" | append_section "Ubuntu .deb package smoke"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-lockout.XXXXXX")"
cleanup() {
    set +e
    as_root rm -f "$SERVICE_FILE"
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cat > "$TMP/native-pam-lockout-client.c" <<'EOF'
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *candidate;

static int lockout_conv(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr) {
  (void)appdata_ptr;
  struct pam_response *responses = calloc((size_t)num_msg, sizeof(struct pam_response));
  if (responses == NULL) {
    return PAM_BUF_ERR;
  }
  for (int i = 0; i < num_msg; i++) {
    switch (msg[i]->msg_style) {
    case PAM_PROMPT_ECHO_OFF:
    case PAM_PROMPT_ECHO_ON:
      responses[i].resp = strdup(candidate);
      if (responses[i].resp == NULL) {
        free(responses);
        return PAM_BUF_ERR;
      }
      break;
    case PAM_TEXT_INFO:
    case PAM_ERROR_MSG:
      if (msg[i]->msg != NULL) {
        fprintf(stderr, "pam_message[%d]=%s\n", msg[i]->msg_style, msg[i]->msg);
      }
      responses[i].resp = NULL;
      break;
    default:
      free(responses);
      return PAM_CONV_ERR;
    }
  }
  *resp = responses;
  return PAM_SUCCESS;
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s <service> <user> <password>\n", argv[0]);
    return 2;
  }
  candidate = argv[3];
  struct pam_conv conv = {lockout_conv, NULL};
  pam_handle_t *pamh = NULL;
  int rc = pam_start(argv[1], argv[2], &conv, &pamh);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_start: %s\n", pam_strerror(pamh, rc));
    return 2;
  }
  rc = pam_chauthtok(pamh, PAM_SILENT);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_chauthtok: %s\n", pam_strerror(pamh, rc));
  }
  int end_rc = pam_end(pamh, rc);
  if (end_rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_end: %d\n", end_rc);
    return 2;
  }
  return rc == PAM_SUCCESS ? 0 : 1;
}
EOF

cat > "$TMP/pam_lockout_authtok.c" <<'EOF'
#include <security/pam_appl.h>
#include <security/pam_modules.h>
#include <stdlib.h>

PAM_EXTERN int pam_sm_chauthtok(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)argc;
  (void)argv;
  if ((flags & PAM_PRELIM_CHECK) != 0) {
    return PAM_SUCCESS;
  }
  if ((flags & PAM_UPDATE_AUTHTOK) == 0) {
    return PAM_IGNORE;
  }
  const char *token = getenv("PWNED_CHECK_TEST_LOCKOUT_TOKEN");
  if (token == NULL) {
    return PAM_AUTHTOK_ERR;
  }
  return pam_set_item(pamh, PAM_AUTHTOK, token);
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags, int argc, const char **argv) {
  (void)pamh; (void)flags; (void)argc; (void)argv; return PAM_IGNORE;
}
EOF

cc -Wall -Wextra -Werror -o "$TMP/native-pam-lockout-client" "$TMP/native-pam-lockout-client.c" -lpam
cc -Wall -Wextra -Werror -fPIC -shared -o "$TMP/pam_lockout_authtok.so" "$TMP/pam_lockout_authtok.c" -lpam

(
    cd "$ROOT"
    make native-pam-build >/dev/null
)
MODULE_PATH="$ROOT/target/release/libpam_pwned_check.so"
[ -x "$MODULE_PATH" ] || fail "native PAM module was not built at $MODULE_PATH"

write_baseline_service() {
    as_root sh -c "cat > '$SERVICE_FILE'" <<EOF
password required $TMP/pam_lockout_authtok.so
password required pam_permit.so
EOF
}

write_broken_service() {
    as_root sh -c "cat > '$SERVICE_FILE'" <<EOF
password required $TMP/pam_lockout_authtok.so
password requisite $MODULE_PATH checker=/tmp/pwned-check-native-missing-checker timeout=1 fail_closed
password required pam_permit.so
EOF
}

run_lockout_client() {
    token="$1"
    output="$2"
    PWNED_CHECK_TEST_LOCKOUT_TOKEN="$token" "$TMP/native-pam-lockout-client" "$SERVICE" root "$token" >"$output" 2>&1
}

LOCKOUT_TOKEN="NativePamLockoutDrill123"
BASELINE_OUT="$RUN_DIR/lockout-baseline-pass.txt"
BROKEN_OUT="$RUN_DIR/lockout-broken-reject.txt"
RESTORED_OUT="$RUN_DIR/lockout-restored-pass.txt"

write_baseline_service
run_lockout_client "$LOCKOUT_TOKEN" "$BASELINE_OUT" || fail "baseline disposable PAM service did not pass"

write_broken_service
set +e
run_lockout_client "$LOCKOUT_TOKEN" "$BROKEN_OUT"
BROKEN_RC="$?"
set -e
[ "$BROKEN_RC" -ne 0 ] || fail "broken disposable PAM service unexpectedly passed"
grep -F "Password breach check failed. Try again later or contact your administrator." "$BROKEN_OUT" >/dev/null || fail "broken service did not emit expected safe failure conversation"

write_baseline_service
run_lockout_client "$LOCKOUT_TOKEN" "$RESTORED_OUT" || fail "restored disposable PAM service did not pass"

cat "$BASELINE_OUT" | append_section "Lockout drill baseline"
cat "$BROKEN_OUT" | append_section "Lockout drill broken service"
cat "$RESTORED_OUT" | append_section "Lockout drill restored service"

if command -v aa-status >/dev/null 2>&1; then
    run_capture "AppArmor status after smoke" as_root aa-status
fi
if command -v journalctl >/dev/null 2>&1; then
    set +e
    as_root journalctl -k --since "$START_JOURNAL" >"$APPARMOR_LOG" 2>&1
    JOURNAL_RC="$?"
    set -e
    if [ "$JOURNAL_RC" -ne 0 ]; then
        printf 'journalctl exited with rc=%s\n' "$JOURNAL_RC" >>"$APPARMOR_LOG"
    fi
else
    printf 'journalctl not installed\n' >"$APPARMOR_LOG"
fi
cat "$APPARMOR_LOG" | append_section "Kernel journal after smoke"

if grep -Ei 'apparmor=.*DENIED|audit.*apparmor.*DENIED' "$APPARMOR_LOG" | grep -Ei 'pwned-check|pam_pwned_check|pwned_check|native-pam' >"$RUN_DIR/matching-apparmor-denials.txt"; then
    MATCHING_DENIALS="$(wc -l <"$RUN_DIR/matching-apparmor-denials.txt" | tr -d ' ')"
else
    MATCHING_DENIALS=0
fi

{
    printf '\n## Assessment Summary\n\n'
    printf 'Ubuntu .deb package smoke result: %s\n' "$SMOKE_RC"
    printf 'Lockout broken service result: %s\n' "$BROKEN_RC"
    printf 'Matching AppArmor denial lines: %s\n' "$MATCHING_DENIALS"
    printf 'Output directory: %s\n' "$RUN_DIR"
    printf 'Completed: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >>"$COMBINED"

if grep -F "$LOCKOUT_TOKEN" "$BASELINE_OUT" "$BROKEN_OUT" "$RESTORED_OUT" >/dev/null; then
    fail "lockout drill leaked the candidate token into PAM output"
fi

if [ "$SMOKE_RC" -ne 0 ]; then
    printf 'Native PAM Ubuntu hardening assessment failed: .deb smoke rc=%s\n' "$SMOKE_RC" >&2
    printf 'Report: %s\n' "$COMBINED" >&2
    exit "$SMOKE_RC"
fi
if [ "$MATCHING_DENIALS" -ne 0 ]; then
    printf 'Native PAM Ubuntu hardening assessment failed: matching AppArmor denials found\n' >&2
    printf 'Report: %s\n' "$COMBINED" >&2
    exit 1
fi

trap - EXIT INT TERM
cleanup
printf 'Native PAM Ubuntu hardening assessment passed.\n'
printf 'Report: %s\n' "$COMBINED"
