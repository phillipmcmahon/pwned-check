#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${NATIVE_PAM_UBUNTU_IMAGE:-pwned-check-native-pam-ubuntu:24.04}"
CONTAINER="${NATIVE_PAM_UBUNTU_CONTAINER:-pwned-check-native-pam-dev}"
PLATFORM="${NATIVE_PAM_UBUNTU_PLATFORM:-}"
WORKDIR="/workspace/pwned-check"
SERVICE="pwned-check-native-smoke"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-ubuntu-smoke.sh [COMMAND]

Build and reuse a persistent Ubuntu container for native PAM module smoke tests.

Commands:
  run          Build/start the container, sync the repo, and run the smoke test (default)
  build-image  Build the reusable Ubuntu development image
  start        Create/start the persistent container
  shell        Open a shell in the persistent container
  reset        Remove and recreate the persistent container
  clean        Remove the persistent container
  help         Show this help text

Environment:
  NATIVE_PAM_UBUNTU_IMAGE      Image name (default: pwned-check-native-pam-ubuntu:24.04)
  NATIVE_PAM_UBUNTU_CONTAINER  Container name (default: pwned-check-native-pam-dev)
  NATIVE_PAM_UBUNTU_PLATFORM   Optional Docker platform, such as linux/amd64
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

docker_platform_args() {
    if [ -n "$PLATFORM" ]; then
        printf '%s\n' "--platform=$PLATFORM"
    fi
}

build_image() {
    tmp="$(mktemp -d)"
    cleanup_tmp() {
        rm -rf "$tmp"
    }
    trap cleanup_tmp EXIT INT TERM

    cat > "$tmp/Dockerfile" <<'EOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        build-essential \
        ca-certificates \
        curl \
        file \
        gcc \
        libpam0g-dev \
        make \
        pkg-config \
        tar \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable \
    && rustup component add rustfmt

WORKDIR /workspace
CMD ["sleep", "infinity"]
EOF

    docker build $(docker_platform_args) -t "$IMAGE" "$tmp"
    trap - EXIT INT TERM
    cleanup_tmp
}

container_exists() {
    docker inspect "$CONTAINER" >/dev/null 2>&1
}

container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]
}

start_container() {
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        build_image
    fi

    if ! container_exists; then
        docker create $(docker_platform_args) --name "$CONTAINER" "$IMAGE" >/dev/null
    fi

    if ! container_running; then
        docker start "$CONTAINER" >/dev/null
    fi
}

reset_container() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    start_container
}

clean_container() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}

sync_repo() {
    docker exec "$CONTAINER" sh -lc "rm -rf '$WORKDIR' && mkdir -p '$WORKDIR'"
    if [ "$(uname -s)" = "Darwin" ]; then
        TAR_XATTR_FLAGS="--no-xattrs"
    elif tar --help 2>/dev/null | grep -q -- '--no-xattrs'; then
        TAR_XATTR_FLAGS="--no-xattrs"
    else
        TAR_XATTR_FLAGS=""
    fi
    COPYFILE_DISABLE=1 tar $TAR_XATTR_FLAGS \
        --exclude=.git \
        --exclude=dist \
        --exclude=target \
        -C "$ROOT" \
        -cf - . \
        | docker exec -i "$CONTAINER" tar -C "$WORKDIR" -xf -
}

write_smoke_client() {
    docker exec -i "$CONTAINER" sh -c "cat > /tmp/native-pam-smoke-client.c" <<'EOF'
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
    docker exec "$CONTAINER" sh -lc "cc -Wall -Wextra -Werror -o /usr/local/bin/native-pam-smoke-client /tmp/native-pam-smoke-client.c -lpam"

    docker exec -i "$CONTAINER" sh -c "cat > /tmp/pam_smoke_authtok.c" <<'EOF'
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
  const char *token = getenv("PWNED_CHECK_NATIVE_SMOKE_TOKEN");
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
}

run_smoke() {
    start_container
    sync_repo
    write_smoke_client

    docker exec "$CONTAINER" sh -lc "
        set -eu
        cd '$WORKDIR'
        make native-pam-fmt
        make native-pam-test
        make native-pam-deps
        make native-pam-symbols

        module_dir=\"/lib/\$(gcc -print-multiarch)/security\"
        install -d \"\$module_dir\"
        install -m 0644 dist/pam_pwned_check.so \"\$module_dir/pam_pwned_check.so\"
        cc -Wall -Wextra -Werror -fPIC -shared -o \"\$module_dir/pam_smoke_authtok.so\" /tmp/pam_smoke_authtok.c -lpam

        cat > /usr/local/bin/native-pam-smoke-checker <<'CHECKER_EOF'
#!/bin/sh
set -eu
token=\"\$(/bin/cat)\"
printf '%s' \"\$token\" >/tmp/native-pam-smoke-checker-token
mode=\"\$(/bin/cat /tmp/native-pam-smoke-checker-mode)\"
case \"\$mode\" in
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
    if [ \"\${PWNED_CHECK_FAIL_CLOSED:-}\" = \"true\" ]; then
      exit 3
    fi
    exit 0
    ;;
  sleep)
    /bin/sleep 3
    exit 0
    ;;
  *)
    exit 9
    ;;
esac
CHECKER_EOF
        chmod 0755 /usr/local/bin/native-pam-smoke-checker

        write_service() {
          args=\"\$1\"
          {
            echo 'password required pam_smoke_authtok.so'
            echo \"password requisite pam_pwned_check.so checker=/usr/local/bin/native-pam-smoke-checker timeout=1 \$args\"
            echo 'password required pam_permit.so'
          } > '/etc/pam.d/$SERVICE'
        }

        run_case() {
          name=\"\$1\"
          mode=\"\$2\"
          token=\"\$3\"
          args=\"\$4\"
          want=\"\$5\"

          printf '%s' \"\$mode\" >/tmp/native-pam-smoke-checker-mode
          rm -f /tmp/native-pam-smoke-checker-token
          write_service \"\$args\"

          set +e
          PWNED_CHECK_NATIVE_SMOKE_TOKEN=\"\$token\" /usr/local/bin/native-pam-smoke-client '$SERVICE' root \"\$token\" >/tmp/native-pam-smoke.out 2>&1
          rc=\"\$?\"
          set -e

          if [ \"\$want\" = allow ] && [ \"\$rc\" -ne 0 ]; then
            cat /tmp/native-pam-smoke.out >&2
            echo \"Native PAM case failed: \$name rc=\$rc want allow\" >&2
            exit 1
          fi
          if [ \"\$want\" = reject ] && [ \"\$rc\" -eq 0 ]; then
            cat /tmp/native-pam-smoke.out >&2
            echo \"Native PAM case failed: \$name rc=\$rc want reject\" >&2
            exit 1
          fi

          if echo \"\$args\" | grep -q 'fail_clsoed'; then
            if [ -f /tmp/native-pam-smoke-checker-token ]; then
              echo \"Native PAM case failed: \$name unexpectedly invoked checker\" >&2
              exit 1
            fi
          elif [ -f /tmp/native-pam-smoke-checker-token ] && [ \"\$mode\" != sleep ]; then
            received=\"\$(cat /tmp/native-pam-smoke-checker-token)\"
            if [ \"\$received\" != \"\$token\" ] && [ \"\$mode\" != config ]; then
              echo \"Native PAM case failed: \$name checker token mismatch\" >&2
              exit 1
            fi
          fi

          echo \"Native PAM case passed: \$name\"
        }

        test -f \"\$module_dir/pam_pwned_check.so\"
        ldd \"\$module_dir/pam_pwned_check.so\"

        run_case 'clean allowed' clean candidate 'fail_open' allow
        run_case 'pwned rejected' pwned password 'fail_open' reject
        run_case 'provider unavailable fail-open allowed' provider candidate 'fail_open' allow
        run_case 'provider unavailable fail-closed rejected' provider candidate 'fail_closed' reject
        run_case 'checker config rejected' config candidate 'fail_open' reject
        run_case 'checker timeout rejected' sleep candidate 'fail_open' reject
        run_case 'dry-run pwned allowed' pwned password 'fail_open dry_run' allow
        run_case 'invalid module arg rejected' clean candidate 'fail_clsoed' reject
    "

    echo "Native PAM Ubuntu smoke passed in persistent container: $CONTAINER"
}

require_command docker

case "${1:-run}" in
    run)
        run_smoke
        ;;
    build-image)
        build_image
        ;;
    start)
        start_container
        echo "Native PAM Ubuntu container is running: $CONTAINER"
        ;;
    shell)
        start_container
        docker exec -it "$CONTAINER" bash
        ;;
    reset)
        reset_container
        echo "Native PAM Ubuntu container was reset: $CONTAINER"
        ;;
    clean)
        clean_container
        echo "Native PAM Ubuntu container removed: $CONTAINER"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        usage >&2
        fail "unknown command: $1"
        ;;
esac
