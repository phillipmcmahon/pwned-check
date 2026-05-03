#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${NATIVE_PAM_GENERIC_PACKAGE_SMOKE_PLATFORM:-linux/amd64}"
IMAGES="${NATIVE_PAM_GENERIC_PACKAGE_SMOKE_IMAGES:-archlinux:base-devel alpine:3.20}"
WORKDIR="/workspace/pwned-check"
SERVICE="pwned-check-native-generic-package-smoke"
PREBUILT_CHECKER=""

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-generic-package-smoke.sh [OPTIONS]

Build the generic native PAM artifact inside Arch/Alpine containers, install it,
enable it through the manual PAM helper, exercise real pam_chauthtok behavior,
and verify rollback.

Options:
  --platform <platform>   Docker platform, currently linux/amd64
  --images "<images>"     Space-separated image list override
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
        --images)
            [ "$#" -ge 2 ] || fail "--images requires a value"
            IMAGES="$2"
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
    *) fail "unsupported platform for native PAM generic package smoke: $PLATFORM" ;;
esac

require_command docker

build_package_checker() {
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-generic-checker.XXXXXX")"
    PREBUILT_CHECKER="$tmp/pwned-check"
    case "$PLATFORM" in
        linux/amd64)
            goarch=amd64
            goamd64="${GOAMD64:-v1}"
            ;;
        *)
            fail "unsupported checker build platform: $PLATFORM"
            ;;
    esac
    (
        cd "$ROOT"
        CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOAMD64="$goamd64" \
            go build -trimpath \
            -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=generic-smoke" \
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

run_in_container() {
    cid="$1"
    family="$2"
    docker exec "$cid" sh -lc "
        set -eu

        install_dependencies() {
          if command -v pacman >/dev/null 2>&1; then
            if [ -f /etc/pacman.conf ]; then
              sed -i 's/^DownloadUser[[:space:]]*=/#DownloadUser =/' /etc/pacman.conf
            fi
            pacman -Sy --noconfirm --needed ca-certificates file gcc make pam pkgconf rust tar
            return
          fi
          if command -v apk >/dev/null 2>&1; then
            apk add --no-cache ca-certificates cargo file gcc linux-pam linux-pam-dev make musl-dev pkgconf rust tar
            return
          fi
          echo 'unsupported package manager for generic native PAM package smoke' >&2
          exit 1
        }

        module_dir() {
          securedir=\"\$(pkg-config --variable=securedir pam 2>/dev/null || true)\"
          if [ -n \"\$securedir\" ]; then
            printf '%s\n' \"\$securedir\"
            return
          fi
          if command -v pacman >/dev/null 2>&1; then
            printf '%s\n' /usr/lib/security
            return
          fi
          if command -v apk >/dev/null 2>&1; then
            if [ -f /usr/lib/security/pam_permit.so ]; then
              printf '%s\n' /usr/lib/security
            else
              printf '%s\n' /lib/security
            fi
            return
          fi
          printf '%s\n' /lib/security
        }

        install_dependencies
        cd '$WORKDIR'
        artifact_name=\"\$(./scripts/package-native-pam-generic-artifact.sh --version generic-smoke --family '$family' --pwned-check-bin /tmp/native-pam-generic-pwned-check)\"
        artifact=\"dist/release/\$artifact_name.tar.gz\"
        test -f \"\$artifact\"
        tar -tzf \"\$artifact\" | grep -F \"/usr/share/pwned-check/manual-pam/enable-manual-pam.sh\" >/dev/null
        tar -tzf \"\$artifact\" | grep -F \"/usr/share/pwned-check/manual-pam/rollback-manual-pam.sh\" >/dev/null
        rm -rf /tmp/native-pam-generic-package
        mkdir -p /tmp/native-pam-generic-package
        tar -xzf \"\$artifact\" -C /tmp/native-pam-generic-package
        cd \"/tmp/native-pam-generic-package/\$artifact_name\"
        ./install.sh

        module_dir=\"\$(module_dir)\"
        test -x /usr/bin/pwned-check
        test -x \"\$module_dir/pam_pwned_check.so\"
        test -x /usr/share/pwned-check/manual-pam/enable-manual-pam.sh
        test -x /usr/share/pwned-check/manual-pam/rollback-manual-pam.sh

        cat > /tmp/native-pam-generic-authtok.c <<'AUTHTOK_EOF'
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
  const char *token = getenv(\"PWNED_CHECK_NATIVE_GENERIC_TOKEN\");
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
AUTHTOK_EOF
        cc -Wall -Wextra -Werror -fPIC -shared -o \"\$module_dir/pam_smoke_authtok.so\" /tmp/native-pam-generic-authtok.c -lpam

        cat > /tmp/native-pam-generic-client.c <<'CLIENT_EOF'
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
        fprintf(stderr, \"pam_message[%d]=%s\n\", msg[i]->msg_style, msg[i]->msg);
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
    fprintf(stderr, \"usage: %s <service> <user> <password>\n\", argv[0]);
    return 2;
  }
  candidate = argv[3];
  struct pam_conv conv = {smoke_conv, NULL};
  pam_handle_t *pamh = NULL;
  int rc = pam_start(argv[1], argv[2], &conv, &pamh);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, \"pam_start: %s\n\", pam_strerror(pamh, rc));
    return 2;
  }
  rc = pam_chauthtok(pamh, PAM_SILENT);
  if (rc != PAM_SUCCESS) {
    fprintf(stderr, \"pam_chauthtok: %s\n\", pam_strerror(pamh, rc));
  }
  int end_rc = pam_end(pamh, rc);
  if (end_rc != PAM_SUCCESS) {
    fprintf(stderr, \"pam_end: %d\n\", end_rc);
    return 2;
  }
  return rc == PAM_SUCCESS ? 0 : 1;
}
CLIENT_EOF
        cc -Wall -Wextra -Werror -o /usr/local/bin/native-pam-generic-client /tmp/native-pam-generic-client.c -lpam

        cat > /usr/local/bin/native-pam-generic-checker <<'CHECKER_EOF'
#!/bin/sh
set -eu
printf '%s' \"\$*\" >/tmp/native-pam-generic-checker-argv
token=\"\$(cat)\"
printf '%s' \"\$token\" >/tmp/native-pam-generic-checker-token
case \"\$(cat /tmp/native-pam-generic-checker-mode)\" in
  clean) exit 0 ;;
  pwned) exit 1 ;;
  *) exit 9 ;;
esac
CHECKER_EOF
        chmod 0755 /usr/local/bin/native-pam-generic-checker

        {
          echo 'password required pam_smoke_authtok.so'
          echo 'password required pam_permit.so'
        } > '/etc/pam.d/$SERVICE'

        PWNED_CHECK_PAM_SERVICE_PATH='/etc/pam.d/$SERVICE' \
        PWNED_CHECK_MODULE_LINE='password requisite pam_pwned_check.so checker=/usr/local/bin/native-pam-generic-checker timeout=1 fail_open' \
        PWNED_CHECK_INSERT_AFTER_PATTERN='pam_smoke_authtok.so' \
            /usr/share/pwned-check/manual-pam/enable-manual-pam.sh
        grep -F 'pam_pwned_check.so' '/etc/pam.d/$SERVICE' >/dev/null

        run_case() {
          name=\"\$1\"
          mode=\"\$2\"
          token=\"\$3\"
          want=\"\$4\"
          printf '%s' \"\$mode\" >/tmp/native-pam-generic-checker-mode
          rm -f /tmp/native-pam-generic-checker-argv /tmp/native-pam-generic-checker-token /tmp/native-pam-generic.out
          set +e
          PWNED_CHECK_NATIVE_GENERIC_TOKEN=\"\$token\" /usr/local/bin/native-pam-generic-client '$SERVICE' root \"\$token\" >/tmp/native-pam-generic.out 2>&1
          rc=\"\$?\"
          set -e
          if [ \"\$want\" = allow ] && [ \"\$rc\" -ne 0 ]; then
            cat /tmp/native-pam-generic.out >&2
            echo \"Native PAM generic package case failed: \$name rc=\$rc want allow\" >&2
            exit 1
          fi
          if [ \"\$want\" = reject ] && [ \"\$rc\" -eq 0 ]; then
            cat /tmp/native-pam-generic.out >&2
            echo \"Native PAM generic package case failed: \$name rc=\$rc want reject\" >&2
            exit 1
          fi
          if [ \"\$(cat /tmp/native-pam-generic-checker-argv)\" != '--stdin' ]; then
            echo \"Native PAM generic package case failed: \$name checker argv mismatch\" >&2
            exit 1
          fi
          if [ \"\$(cat /tmp/native-pam-generic-checker-token)\" != \"\$token\" ]; then
            echo \"Native PAM generic package case failed: \$name checker token mismatch\" >&2
            exit 1
          fi
          if grep -F \"\$token\" /tmp/native-pam-generic.out >/dev/null; then
            cat /tmp/native-pam-generic.out >&2
            echo \"Native PAM generic package case failed: \$name leaked token to PAM output\" >&2
            exit 1
          fi
          echo \"Native PAM generic package case passed: \$name\"
        }

        run_case 'clean allowed' clean NativeGenericClean123 allow
        run_case 'pwned rejected' pwned NativeGenericPwned123 reject

        PWNED_CHECK_PAM_SERVICE_PATH='/etc/pam.d/$SERVICE' /usr/share/pwned-check/manual-pam/rollback-manual-pam.sh
        if grep -F 'pam_pwned_check.so' '/etc/pam.d/$SERVICE' >/dev/null; then
          cat '/etc/pam.d/$SERVICE' >&2
          echo 'Native PAM generic package rollback left module configured' >&2
          exit 1
        fi
        printf '%s' pwned >/tmp/native-pam-generic-checker-mode
        PWNED_CHECK_NATIVE_GENERIC_TOKEN='NativeGenericRollback123' /usr/local/bin/native-pam-generic-client '$SERVICE' root 'NativeGenericRollback123' >/tmp/native-pam-generic.out 2>&1

        pretty_name=\"\$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '\"')\"
        echo \"Native PAM generic package smoke passed: \$pretty_name\"
    "
}

cleanup_prebuilt() {
    if [ -n "$PREBUILT_CHECKER" ]; then
        rm -rf "$(dirname "$PREBUILT_CHECKER")"
    fi
}
trap cleanup_prebuilt EXIT INT TERM
build_package_checker

for image in $IMAGES; do
    case "$image" in
        archlinux:*) family="arch" ;;
        alpine:*) family="alpine" ;;
        *) family="generic" ;;
    esac
    echo "Native PAM generic package smoke: $image ($PLATFORM)"
    cid="$(docker create --platform "$PLATFORM" "$image" sleep infinity)"
    cleanup_container() {
        docker rm -f "$cid" >/dev/null 2>&1 || true
    }
    trap cleanup_container EXIT INT TERM
    docker start "$cid" >/dev/null
    sync_repo "$cid"
    docker cp "$PREBUILT_CHECKER" "$cid:/tmp/native-pam-generic-pwned-check"
    run_in_container "$cid" "$family"
    docker rm -f "$cid" >/dev/null
    trap - EXIT INT TERM
done

cleanup_prebuilt
echo "Native PAM generic package smoke matrix passed"
