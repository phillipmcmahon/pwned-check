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

        cat > '/etc/pam.d/$SERVICE' <<'SERVICE_EOF'
password required pam_pwned_check.so debug
password required pam_permit.so
SERVICE_EOF

        test -f \"\$module_dir/pam_pwned_check.so\"
        ldd \"\$module_dir/pam_pwned_check.so\"
        /usr/local/bin/native-pam-smoke-client '$SERVICE' root candidate
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
