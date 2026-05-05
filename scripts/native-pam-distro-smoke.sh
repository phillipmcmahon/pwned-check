#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PLATFORM="${NATIVE_PAM_DISTRO_SMOKE_PLATFORM:-linux/amd64}"
IMAGES="${NATIVE_PAM_DISTRO_SMOKE_IMAGES:-debian:stable-slim ubuntu:24.04 fedora:latest archlinux:base-devel alpine:3.22}"
WORKDIR="/workspace/pwned-check"
SERVICE="pwned-check-native-distro-smoke"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-distro-smoke.sh [OPTIONS]

Build pam_pwned_check.so inside throwaway distro containers and exercise it
through a real Linux PAM password stack.

Options:
  --platform <platform>   Docker platform, currently linux/amd64
  --images "<images>"     Space-separated image list override
  --help                  Show this help text

Environment:
  NATIVE_PAM_DISTRO_SMOKE_PLATFORM  Docker platform (default: linux/amd64)
  NATIVE_PAM_DISTRO_SMOKE_IMAGES    Space-separated image list override
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
        --help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

case "$PLATFORM" in
    linux/amd64)
        ;;
    *)
        fail "unsupported platform for native PAM distro smoke: $PLATFORM"
        ;;
esac

require_command docker
require_command git

sync_repo() {
    cid="$1"
    docker exec "$cid" sh -lc "rm -rf '$WORKDIR' && mkdir -p '$WORKDIR'"
    tmp="$(mktemp -d)"
    (
        cd "$ROOT"
        git ls-files | while IFS= read -r path; do
            mkdir -p "$tmp/$(dirname "$path")"
            cp "$path" "$tmp/$path"
        done
    )
    docker cp "$tmp/." "$cid:$WORKDIR"
    rm -rf "$tmp"
}

run_in_container() {
    cid="$1"
    docker exec "$cid" sh -lc "
        set -eu

        install_native_pam_dependencies() {
          if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y --no-install-recommends build-essential ca-certificates curl file libpam0g-dev make pkg-config
            rm -rf /var/lib/apt/lists/*
            curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
              | sh -s -- -y --profile minimal --default-toolchain stable
            export PATH=\"\$HOME/.cargo/bin:\$PATH\"
            return
          fi
          if command -v dnf >/dev/null 2>&1; then
            dnf install -y ca-certificates cargo file gcc make pam-devel pkgconf-pkg-config rust
            dnf clean all
            return
          fi
          if command -v pacman >/dev/null 2>&1; then
            if [ -f /etc/pacman.conf ]; then
              sed -i 's/^DownloadUser[[:space:]]*=/#DownloadUser =/' /etc/pacman.conf
            fi
            pacman -Sy --noconfirm --needed ca-certificates file gcc make pam pkgconf rust
            return
          fi
          if command -v apk >/dev/null 2>&1; then
            apk add --no-cache ca-certificates cargo file gcc linux-pam-dev make musl-dev pkgconf rust
            return
          fi
          echo 'unsupported package manager' >&2
          exit 1
        }

        pam_module_dir() {
          securedir=\"\$(pkg-config --variable=securedir pam 2>/dev/null || true)\"
          if [ -n \"\$securedir\" ]; then
            printf '%s\n' \"\$securedir\"
            return
          fi
          if command -v dnf >/dev/null 2>&1; then
            printf '%s\n' /lib64/security
            return
          fi
          if [ -d /usr/lib/security ]; then
            printf '%s\n' /usr/lib/security
            return
          fi
          if command -v gcc >/dev/null 2>&1 && multiarch=\"\$(gcc -print-multiarch 2>/dev/null)\" && [ -n \"\$multiarch\" ]; then
            printf '%s\n' \"/lib/\$multiarch/security\"
            return
          fi
          printf '%s\n' /lib/security
        }

        install_native_pam_dependencies
        if [ -d \"\$HOME/.cargo/bin\" ]; then
          export PATH=\"\$HOME/.cargo/bin:\$PATH\"
        fi
        cd '$WORKDIR'
        if command -v apk >/dev/null 2>&1; then
          echo 'native PAM Rust unit tests skipped in Alpine distro smoke; covered by non-Alpine distro smoke and host gates'
        else
          cargo test -p pam-pwned-check
        fi
        cargo build --release -p pam-pwned-check

        module_dir=\"\$(pam_module_dir)\"
        install -d \"\$module_dir\"
        install -m 0755 target/release/libpam_pwned_check.so \"\$module_dir/pam_pwned_check.so\"
        test -f \"\$module_dir/pam_pwned_check.so\"
        ldd \"\$module_dir/pam_pwned_check.so\" || true

        cat > /tmp/native-pam-distro-authtok.c <<'AUTHTOK_EOF'
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
  const char *token = getenv(\"PWNED_CHECK_NATIVE_DISTRO_TOKEN\");
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
        cc -Wall -Wextra -Werror -fPIC -shared -o \"\$module_dir/pam_smoke_authtok.so\" /tmp/native-pam-distro-authtok.c -lpam

        cat > /tmp/native-pam-distro-client.c <<'CLIENT_EOF'
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
        cc -Wall -Wextra -Werror -o /usr/local/bin/native-pam-distro-client /tmp/native-pam-distro-client.c -lpam

        cat > /usr/local/bin/native-pam-distro-checker <<'CHECKER_EOF'
#!/bin/sh
set -eu
printf '%s' \"\$*\" >/tmp/native-pam-distro-checker-argv
token=\"\$(cat)\"
printf '%s' \"\$token\" >/tmp/native-pam-distro-checker-token
case \"\$(cat /tmp/native-pam-distro-checker-mode)\" in
  clean) exit 0 ;;
  pwned) exit 1 ;;
  *) exit 9 ;;
esac
CHECKER_EOF
        chmod 0755 /usr/local/bin/native-pam-distro-checker

        install -d /etc/pam.d
        {
          echo 'password required pam_smoke_authtok.so'
          echo 'password requisite pam_pwned_check.so checker=/usr/local/bin/native-pam-distro-checker timeout=1 fail_open'
          echo 'password required pam_permit.so'
        } > '/etc/pam.d/$SERVICE'

        run_case() {
          name=\"\$1\"
          mode=\"\$2\"
          token=\"\$3\"
          want=\"\$4\"
          printf '%s' \"\$mode\" >/tmp/native-pam-distro-checker-mode
          rm -f /tmp/native-pam-distro-checker-argv /tmp/native-pam-distro-checker-token /tmp/native-pam-distro.out
          set +e
          PWNED_CHECK_NATIVE_DISTRO_TOKEN=\"\$token\" /usr/local/bin/native-pam-distro-client '$SERVICE' root \"\$token\" >/tmp/native-pam-distro.out 2>&1
          rc=\"\$?\"
          set -e
          if [ \"\$want\" = allow ] && [ \"\$rc\" -ne 0 ]; then
            cat /tmp/native-pam-distro.out >&2
            echo \"Native PAM distro case failed: \$name rc=\$rc want allow\" >&2
            exit 1
          fi
          if [ \"\$want\" = reject ] && [ \"\$rc\" -eq 0 ]; then
            cat /tmp/native-pam-distro.out >&2
            echo \"Native PAM distro case failed: \$name rc=\$rc want reject\" >&2
            exit 1
          fi
          if [ \"\$(cat /tmp/native-pam-distro-checker-argv)\" != '--stdin' ]; then
            echo \"Native PAM distro case failed: \$name checker argv mismatch\" >&2
            exit 1
          fi
          if [ \"\$(cat /tmp/native-pam-distro-checker-token)\" != \"\$token\" ]; then
            echo \"Native PAM distro case failed: \$name checker token mismatch\" >&2
            exit 1
          fi
          if grep -F \"\$token\" /tmp/native-pam-distro.out >/dev/null; then
            cat /tmp/native-pam-distro.out >&2
            echo \"Native PAM distro case failed: \$name leaked token to PAM output\" >&2
            exit 1
          fi
          echo \"Native PAM distro case passed: \$name\"
        }

        run_case 'clean allowed' clean NativeDistroClean123 allow
        run_case 'pwned rejected' pwned NativeDistroPwned123 reject
        pretty_name=\"\$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '\"')\"
        echo \"Native PAM distro smoke passed: \$pretty_name\"
    "
}

for image in $IMAGES; do
    echo "Native PAM distro smoke: $image ($PLATFORM)"
    cid="$(docker create --platform "$PLATFORM" "$image" sleep infinity)"
    cleanup_container() {
        docker rm -f "$cid" >/dev/null 2>&1 || true
    }
    trap cleanup_container EXIT INT TERM
    docker start "$cid" >/dev/null
    sync_repo "$cid"
    run_in_container "$cid"
    docker rm -f "$cid" >/dev/null
    trap - EXIT INT TERM
done

echo "Native PAM distro smoke matrix passed"
