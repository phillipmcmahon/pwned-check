#!/bin/sh

set -eu

SERVICE="${PWNED_CHECK_MANUAL_SMOKE_SERVICE:-pwned-check-native-manual-installed-smoke}"

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
    echo "native PAM manual installed smoke skipped: Linux host required"
    exit 0
}

require_command cc
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

MODULE_DIR="$(pkg-config --variable=securedir pam 2>/dev/null || true)"
[ -n "$MODULE_DIR" ] || MODULE_DIR="/usr/lib/security"

CHECKER_PATH="/usr/bin/pwned-check"
MODULE_PATH="$MODULE_DIR/pam_pwned_check.so"
ENABLE_HELPER="/usr/share/pwned-check/manual-pam/enable-manual-pam.sh"
ROLLBACK_HELPER="/usr/share/pwned-check/manual-pam/rollback-manual-pam.sh"
SERVICE_FILE="/etc/pam.d/$SERVICE"

[ -x "$CHECKER_PATH" ] || fail "checker is not installed at $CHECKER_PATH"
[ -x "$MODULE_PATH" ] || fail "module is not installed at $MODULE_PATH"
[ -x "$ENABLE_HELPER" ] || fail "manual PAM enable helper is not installed at $ENABLE_HELPER"
[ -x "$ROLLBACK_HELPER" ] || fail "manual PAM rollback helper is not installed at $ROLLBACK_HELPER"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-manual-installed.XXXXXX")"
STATE_FILE="$TMP/manual-pam-last-backup"
BACKUP_DIR="$TMP/backups"

cleanup() {
    set +e
    as_root env \
        PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
        PWNED_CHECK_STATE_FILE="$STATE_FILE" \
        "$ROLLBACK_HELPER" >/dev/null 2>&1
    as_root rm -f "$SERVICE_FILE"
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cat > "$TMP/native-pam-manual-client.c" <<'EOF'
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *candidate;

static int smoke_conv(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr) {
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
  struct pam_conv conv = {smoke_conv, NULL};
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

cat > "$TMP/pam_manual_authtok.c" <<'EOF'
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
  const char *token = getenv("PWNED_CHECK_NATIVE_MANUAL_TOKEN");
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

cc -Wall -Wextra -Werror -o "$TMP/native-pam-manual-client" "$TMP/native-pam-manual-client.c" -lpam
cc -Wall -Wextra -Werror -fPIC -shared -o "$TMP/pam_manual_authtok.so" "$TMP/pam_manual_authtok.c" -lpam

CHECKER="$TMP/native-pam-manual-checker"
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
password required $TMP/pam_manual_authtok.so
password required pam_permit.so
EOF
as_root install -m 0644 "$TMP/service" "$SERVICE_FILE"

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_BACKUP_DIR="$BACKUP_DIR" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    PWNED_CHECK_MODULE_LINE="password requisite pam_pwned_check.so checker=$CHECKER timeout=1 fail_open" \
    PWNED_CHECK_INSERT_AFTER_PATTERN="pam_manual_authtok.so" \
    "$ENABLE_HELPER"
grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null || fail "manual helper did not add pam_pwned_check"

run_case() {
    name="$1"
    mode="$2"
    token="$3"
    want="$4"
    printf '%s' "$mode" >"$TMP/checker-mode"
    rm -f "$TMP/checker-argv" "$TMP/checker-token" "$TMP/case.out"
    set +e
    PWNED_CHECK_NATIVE_MANUAL_TOKEN="$token" "$TMP/native-pam-manual-client" "$SERVICE" root "$token" >"$TMP/case.out" 2>&1
    rc="$?"
    set -e
    if [ "$want" = allow ] && [ "$rc" -ne 0 ]; then
        cat "$TMP/case.out" >&2
        fail "manual installed smoke case failed: $name rc=$rc want allow"
    fi
    if [ "$want" = reject ] && [ "$rc" -eq 0 ]; then
        cat "$TMP/case.out" >&2
        fail "manual installed smoke case failed: $name rc=$rc want reject"
    fi
    [ "$(cat "$TMP/checker-argv")" = "--stdin" ] || fail "manual installed smoke case failed: $name checker argv mismatch"
    [ "$(cat "$TMP/checker-token")" = "$token" ] || fail "manual installed smoke case failed: $name checker token mismatch"
    if grep -F "$token" "$TMP/case.out" >/dev/null; then
        cat "$TMP/case.out" >&2
        fail "manual installed smoke case failed: $name leaked token to PAM output"
    fi
    echo "Native PAM manual installed case passed: $name"
}

run_case "clean allowed" clean NativeManualClean123 allow
run_case "pwned rejected" pwned NativeManualPwned123 reject

as_root env \
    PWNED_CHECK_PAM_SERVICE_PATH="$SERVICE_FILE" \
    PWNED_CHECK_STATE_FILE="$STATE_FILE" \
    "$ROLLBACK_HELPER"
if grep -F 'pam_pwned_check.so' "$SERVICE_FILE" >/dev/null; then
    cat "$SERVICE_FILE" >&2
    fail "manual rollback left pam_pwned_check configured"
fi

trap - EXIT INT TERM
as_root rm -f "$SERVICE_FILE"
rm -rf "$TMP"
echo "Native PAM manual installed smoke passed"
