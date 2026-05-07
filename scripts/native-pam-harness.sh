#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVICE="pwned-check-native-harness-$$"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-harness.sh

Build pam_pwned_check.so and exercise it through a temporary Linux PAM
service on the current host. This is intended for Ubuntu CI runners.
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

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

if [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM harness skipped: Linux host required"
    exit 0
}

require_command cc
require_command make

if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

cd "$ROOT"
make native-pam-build

MODULE="$ROOT/dist/pam_pwned_check.so"
[ -f "$MODULE" ] || fail "native PAM module was not built at $MODULE"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-harness.XXXXXX")"
SERVICE_FILE="/etc/pam.d/$SERVICE"

cleanup() {
    as_root rm -f "$SERVICE_FILE"
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

cat > "$TMP/native-pam-harness-client.c" <<'EOF'
#define _GNU_SOURCE
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *candidate;

static int harness_conv(int num_msg, const struct pam_message **msg, struct pam_response **resp, void *appdata_ptr) {
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
  struct pam_conv conv = {harness_conv, NULL};
  pam_handle_t *pamh = NULL;
  int rc = pam_start(argv[1], argv[2], &conv, &pamh);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, "pam_start: %s\n", pam_strerror(pamh, rc));
    return 2;
  }

  rc = pam_chauthtok(pamh, 0);
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

cat > "$TMP/pam_harness_authtok.c" <<'EOF'
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
  const char *token = getenv("PWNED_CHECK_TEST_HARNESS_TOKEN");
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

cc -Wall -Wextra -Werror -o "$TMP/native-pam-harness-client" "$TMP/native-pam-harness-client.c" -lpam
cc -Wall -Wextra -Werror -fPIC -shared -o "$TMP/pam_harness_authtok.so" "$TMP/pam_harness_authtok.c" -lpam

CHECKER="$TMP/native-pam-harness-checker"
QUOTED_TMP="$(shell_quote "$TMP")"
cat > "$CHECKER" <<EOF
#!/bin/sh
set -eu
HARNESS_TMP=$QUOTED_TMP
printf '%s' "\$*" >"\$HARNESS_TMP/checker-argv"
printf '%s' "\${PWNED_CHECK_FAIL_CLOSED:-}" >"\$HARNESS_TMP/checker-fail-closed"
/usr/bin/env >"\$HARNESS_TMP/checker-env"
printf '%s' "\$\$" >"\$HARNESS_TMP/checker-pid"
token="\$(/bin/cat)"
printf '%s' "\$token" >"\$HARNESS_TMP/checker-token"
mode="\$(/bin/cat "\$HARNESS_TMP/checker-mode")"
case "\$mode" in
  clean)
    exit 0
    ;;
  pwned)
    exit 1
    ;;
  config)
    exit 2
    ;;
  provider)
    if [ "\${PWNED_CHECK_FAIL_CLOSED:-}" = "true" ]; then
      exit 3
    fi
    exit 0
    ;;
  sleep)
    trap '' TERM
    /bin/sleep 30
    exit 0
    ;;
  unexpected)
    exit 9
    ;;
  *)
    exit 8
    ;;
esac
EOF
chmod 0755 "$CHECKER"

write_service() {
    checker="$1"
    args="$2"
    seed_authtok="${3:-yes}"
    service_tmp="$TMP/service"
    {
        if [ "$seed_authtok" = yes ]; then
            printf 'password required %s\n' "$TMP/pam_harness_authtok.so"
        fi
        printf 'password requisite %s checker=%s timeout=1 %s\n' "$MODULE" "$checker" "$args"
        printf 'password required pam_permit.so\n'
    } > "$service_tmp"
    as_root install -m 0644 "$service_tmp" "$SERVICE_FILE"
}

run_case() {
    name="$1"
    mode="$2"
    token="$3"
    args="$4"
    want="$5"
    want_message="$6"
    want_checker="$7"
    want_fail_closed="$8"
    checker_path="$9"
    seed_authtok="${10:-yes}"

    [ "$checker_path" != "-" ] || checker_path="$CHECKER"
    printf '%s' "$mode" >"$TMP/checker-mode"
    rm -f "$TMP/checker-token" "$TMP/checker-argv" "$TMP/checker-fail-closed" "$TMP/checker-env" "$TMP/checker-pid"
    write_service "$checker_path" "$args" "$seed_authtok"

    set +e
    PWNED_CHECK_TEST_HARNESS_TOKEN="$token" \
      PWNED_CHECK_SHOULD_NOT_LEAK='secret' \
      "$TMP/native-pam-harness-client" "$SERVICE" root "$token" >"$TMP/case.out" 2>&1
    rc="$?"
    set -e

    if [ "$want" = allow ] && [ "$rc" -ne 0 ]; then
        cat "$TMP/case.out" >&2
        fail "native PAM harness case failed: $name rc=$rc want allow"
    fi
    if [ "$want" = reject ] && [ "$rc" -eq 0 ]; then
        cat "$TMP/case.out" >&2
        fail "native PAM harness case failed: $name rc=$rc want reject"
    fi

    if [ "$want_message" != "-" ]; then
        if ! grep -F "$want_message" "$TMP/case.out" >/dev/null; then
            cat "$TMP/case.out" >&2
            fail "native PAM harness case failed: $name missing message: $want_message"
        fi
    elif grep -F 'This password appears in a known breach corpus. Choose a different password.' "$TMP/case.out" >/dev/null ||
         grep -F 'Password breach check failed. Try again later or contact your administrator.' "$TMP/case.out" >/dev/null; then
        cat "$TMP/case.out" >&2
        fail "native PAM harness case failed: $name emitted unexpected conversation message"
    fi

    if [ "$want_checker" = no ]; then
        if [ -f "$TMP/checker-token" ]; then
            fail "native PAM harness case failed: $name unexpectedly invoked checker"
        fi
    else
        [ -f "$TMP/checker-argv" ] || fail "native PAM harness case failed: $name did not invoke checker"
        checker_argv="$(cat "$TMP/checker-argv")"
        want_argv="--stdin"
        case " $args " in
            *" min_count=42 "*) want_argv="--stdin --min-count 42" ;;
        esac
        [ "$checker_argv" = "$want_argv" ] || fail "native PAM harness case failed: $name checker argv=$checker_argv want $want_argv"
        checker_fail_closed="$(cat "$TMP/checker-fail-closed")"
        [ "$checker_fail_closed" = "$want_fail_closed" ] || fail "native PAM harness case failed: $name fail_closed=$checker_fail_closed want $want_fail_closed"
        checker_env="$(cat "$TMP/checker-env")"
        if printf '%s' "$checker_env" | grep -F 'PWNED_CHECK_TEST_HARNESS_TOKEN=' >/dev/null ||
           printf '%s' "$checker_env" | grep -F 'PWNED_CHECK_SHOULD_NOT_LEAK=' >/dev/null ||
           printf '%s' "$checker_env" | grep -F 'secret' >/dev/null; then
            fail "native PAM harness case failed: $name leaked caller environment into checker"
        fi
        if [ "$mode" != sleep ]; then
            received="$(cat "$TMP/checker-token")"
            [ "$received" = "$token" ] || fail "native PAM harness case failed: $name checker token mismatch"
        else
            checker_pid="$(cat "$TMP/checker-pid")"
            if kill -0 "$checker_pid" 2>/dev/null; then
                fail "native PAM harness case failed: $name left checker process alive"
            fi
        fi
        if grep -F "$token" "$TMP/case.out" >/dev/null; then
            cat "$TMP/case.out" >&2
            fail "native PAM harness case failed: $name leaked token to PAM output"
        fi
    fi

    echo "Native PAM harness case passed: $name"
}

pwned_message='This password appears in a known breach corpus. Choose a different password.'
failure_message='Password breach check failed. Try again later or contact your administrator.'

run_case 'clean allowed' clean CleanHarness123 'fail_open' allow '-' yes false -
run_case 'pwned rejected' pwned PwnedHarness123 'fail_open' reject "$pwned_message" yes false -
run_case 'provider unavailable fail-open allowed' provider ProviderOpenHarness123 'fail_open' allow '-' yes false -
run_case 'provider unavailable fail-closed rejected' provider ProviderClosedHarness123 'fail_closed' reject "$failure_message" yes true -
run_case 'checker config rejected' config ConfigHarness123 'fail_open' reject "$failure_message" yes false -
run_case 'provider connectivity timeout fail-open allowed' sleep TimeoutOpenHarness123 'fail_open' allow '-' yes false -
run_case 'provider connectivity timeout fail-closed rejected' sleep TimeoutClosedHarness123 'fail_closed' reject "$failure_message" yes true -
run_case 'unexpected checker exit rejected' unexpected UnexpectedHarness123 'fail_open' reject "$failure_message" yes false -
run_case 'checker exec failure rejected' clean ExecHarness123 'fail_open' reject "$failure_message" no '' "$TMP/missing-checker"
run_case 'dry-run pwned allowed' pwned DryRunHarness123 'fail_open dry_run' allow '-' yes false -
run_case 'min-count forwarded' clean MinCountHarness123 'fail_open min_count=42' allow '-' yes false -
run_case 'prompts for missing authtok' clean PromptHarness123 'fail_open' allow '-' yes false - no
run_case 'invalid module arg rejected' clean InvalidArgHarness123 'fail_clsoed' reject "$failure_message" no '' -

echo "Native PAM harness passed"
