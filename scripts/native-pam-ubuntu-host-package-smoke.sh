#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="pwned-check-native-host-package-smoke"
SMOKE_VERSION="${NATIVE_PAM_HOST_SMOKE_VERSION:-host-smoke}"
ALLOW_OVERWRITE="${PWNED_CHECK_HOST_SMOKE_ALLOW_OVERWRITE:-}"
USE_INSTALLED="${PWNED_CHECK_UBUNTU_HOST_SMOKE_USE_INSTALLED:-}"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-ubuntu-host-package-smoke.sh

Build the Debian/Ubuntu native PAM artifact, install its filesystem layout on
the current Ubuntu host, exercise pam_pwned_check.so through a disposable PAM
service, and roll the host back to its pre-test state.

This does not enable the package profile through pam-auth-update and does not
edit /etc/pam.d/common-password.

Environment:
  NATIVE_PAM_HOST_SMOKE_VERSION           Version label for the test artifact
  PWNED_CHECK_HOST_SMOKE_ALLOW_OVERWRITE  Set to 1 to allow pre-existing files
  PWNED_CHECK_UBUNTU_HOST_SMOKE_USE_INSTALLED
                                           Set to 1 to test installed files without building/installing the artifact
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
    echo "native PAM Ubuntu host package smoke skipped: Linux host required"
    exit 0
}

if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    case "$OS_ID" in
        ubuntu|debian) ;;
        *) fail "host package smoke currently supports Debian/Ubuntu hosts only, got ID=${OS_ID:-unknown}" ;;
    esac
fi

require_command cc
require_command gcc
require_command make
require_command tar
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

MULTIARCH="$(gcc -print-multiarch)"
[ -n "$MULTIARCH" ] || fail "could not determine GCC multiarch tuple"
MODULE_PATH="/lib/$MULTIARCH/security/pam_pwned_check.so"
CHECKER_PATH="/usr/bin/pwned-check"
PROFILE_PATH="/usr/share/pam-configs/pwned-check"
DOC_DIR="/usr/share/doc/pwned-check"
SERVICE_FILE="/etc/pam.d/$SERVICE"

managed_paths="$CHECKER_PATH $MODULE_PATH $PROFILE_PATH"
if [ -z "$ALLOW_OVERWRITE" ] && [ -z "$USE_INSTALLED" ]; then
    for path in $managed_paths; do
        [ ! -e "$path" ] || fail "refusing to overwrite existing host install path: $path"
    done
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-host-package.XXXXXX")"
ARTIFACT_DIR="$TMP/artifact"
BACKUP_DIR="$TMP/backups"
mkdir -p "$ARTIFACT_DIR" "$BACKUP_DIR"

backup_existing() {
    path="$1"
    if [ -e "$path" ]; then
        rel="$(printf '%s' "$path" | sed 's,^/,,')"
        mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
        as_root cp -a "$path" "$BACKUP_DIR/$rel"
    fi
}

restore_or_remove() {
    path="$1"
    rel="$(printf '%s' "$path" | sed 's,^/,,')"
    if [ -e "$BACKUP_DIR/$rel" ]; then
        as_root install -d "$(dirname "$path")"
        as_root rm -rf "$path"
        as_root cp -a "$BACKUP_DIR/$rel" "$path"
    else
        as_root rm -rf "$path"
    fi
}

cleanup() {
    as_root rm -f "$SERVICE_FILE"
    if [ -z "$USE_INSTALLED" ]; then
        restore_or_remove "$CHECKER_PATH"
        restore_or_remove "$MODULE_PATH"
        restore_or_remove "$PROFILE_PATH"
        if [ ! -e "$BACKUP_DIR/$(printf '%s' "$DOC_DIR" | sed 's,^/,,')" ]; then
            as_root rm -rf "$DOC_DIR"
        fi
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

if [ -z "$USE_INSTALLED" ]; then
    backup_existing "$CHECKER_PATH"
    backup_existing "$MODULE_PATH"
    backup_existing "$PROFILE_PATH"
    backup_existing "$DOC_DIR"

    cd "$ROOT"
    artifact_name="$(./scripts/package-native-pam-debian-artifact.sh --version "$SMOKE_VERSION")"
    artifact="$ROOT/dist/release/$artifact_name.tar.gz"
    [ -f "$artifact" ] || fail "artifact was not produced: $artifact"
    tar -xzf "$artifact" -C "$ARTIFACT_DIR"
    (
        cd "$ARTIFACT_DIR/$artifact_name"
        as_root ./install.sh
    )
fi

[ -x "$CHECKER_PATH" ] || fail "checker was not installed at $CHECKER_PATH"
[ -f "$MODULE_PATH" ] || fail "module was not installed at $MODULE_PATH"
[ "$(stat -c '%a' "$MODULE_PATH")" = "644" ] || fail "PAM module should be installed mode 0644"
[ -f "$PROFILE_PATH" ] || fail "pam-auth-update profile was not installed at $PROFILE_PATH"
"$CHECKER_PATH" --version >/dev/null

cat > "$TMP/native-pam-host-client.c" <<'EOF'
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *candidate;

static int host_smoke_conv(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr) {
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
  struct pam_conv conv = {host_smoke_conv, NULL};
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

cat > "$TMP/pam_host_authtok.c" <<'EOF'
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
  const char *token = getenv("PWNED_CHECK_NATIVE_HOST_TOKEN");
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

cc -Wall -Wextra -Werror -o "$TMP/native-pam-host-client" "$TMP/native-pam-host-client.c" -lpam
cc -Wall -Wextra -Werror -fPIC -shared -o "$TMP/pam_host_authtok.so" "$TMP/pam_host_authtok.c" -lpam

CHECKER="$TMP/native-pam-host-checker"
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
password required $TMP/pam_host_authtok.so
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
    PWNED_CHECK_NATIVE_HOST_TOKEN="$token" "$TMP/native-pam-host-client" "$SERVICE" root "$token" >"$TMP/case.out" 2>&1
    rc="$?"
    set -e
    if [ "$want" = allow ] && [ "$rc" -ne 0 ]; then
        cat "$TMP/case.out" >&2
        fail "host package smoke case failed: $name rc=$rc want allow"
    fi
    if [ "$want" = reject ] && [ "$rc" -eq 0 ]; then
        cat "$TMP/case.out" >&2
        fail "host package smoke case failed: $name rc=$rc want reject"
    fi
    [ "$(cat "$TMP/checker-argv")" = "--stdin" ] || fail "host package smoke case failed: $name checker argv mismatch"
    [ "$(cat "$TMP/checker-token")" = "$token" ] || fail "host package smoke case failed: $name checker token mismatch"
    if grep -F "$token" "$TMP/case.out" >/dev/null; then
        cat "$TMP/case.out" >&2
        fail "host package smoke case failed: $name leaked token to PAM output"
    fi
    echo "Native PAM Ubuntu host package case passed: $name"
}

run_case "clean allowed" clean HostPackageClean123 allow
run_case "pwned rejected" pwned HostPackagePwned123 reject

as_root rm -f "$SERVICE_FILE"
if [ -z "$USE_INSTALLED" ]; then
    restore_or_remove "$CHECKER_PATH"
    restore_or_remove "$MODULE_PATH"
    restore_or_remove "$PROFILE_PATH"
    if [ ! -e "$BACKUP_DIR/$(printf '%s' "$DOC_DIR" | sed 's,^/,,')" ]; then
        as_root rm -rf "$DOC_DIR"
    fi
fi

[ ! -e "$SERVICE_FILE" ] || fail "disposable PAM service still exists after rollback"
if [ -z "$ALLOW_OVERWRITE" ] && [ -z "$USE_INSTALLED" ]; then
    [ ! -e "$CHECKER_PATH" ] || fail "checker still installed after rollback: $CHECKER_PATH"
    [ ! -e "$MODULE_PATH" ] || fail "module still installed after rollback: $MODULE_PATH"
    [ ! -e "$PROFILE_PATH" ] || fail "profile still installed after rollback: $PROFILE_PATH"
fi
trap - EXIT INT TERM
rm -rf "$TMP"
echo "Native PAM Ubuntu host package smoke passed"
