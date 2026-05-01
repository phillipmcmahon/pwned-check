#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IMAGE="${NATIVE_PAM_UBUNTU_IMAGE:-pwned-check-native-pam-ubuntu:24.04}"
CONTAINER="${NATIVE_PAM_UBUNTU_CONTAINER:-pwned-check-native-pam-dev}"
PLATFORM="${NATIVE_PAM_UBUNTU_PLATFORM:-}"
WORKDIR="/workspace/pwned-check"
SERVICE="pwned-check-native-smoke"
OUTPUT_DIR="${NATIVE_PAM_UBUNTU_OUTPUT_DIR:-$ROOT/.test-output/native-pam-ubuntu-smoke}"
RUN_NAME=""
RUN_DIR=""

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
  NATIVE_PAM_UBUNTU_OUTPUT_DIR Directory for copied smoke logs and artifacts
                                (default: .test-output/native-pam-ubuntu-smoke)
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
        golang-go \
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

prepare_output_dir() {
    RUN_NAME="$(date -u '+%Y%m%dT%H%M%SZ')-native-pam-ubuntu-smoke"
    RUN_DIR="$OUTPUT_DIR/$RUN_NAME"
    rm -rf "$RUN_DIR"
    mkdir -p "$RUN_DIR"
    rm -rf "$OUTPUT_DIR/latest"
    ln -s "$RUN_NAME" "$OUTPUT_DIR/latest"
}

capture_smoke_artifacts() {
    dest="$RUN_DIR"
    mkdir -p "$dest"
    docker exec "$CONTAINER" sh -lc "
        cd /tmp
        for path in native-pam-smoke.out native-pam-smoke-syslog native-pam-smoke-checker-* native-pam-smoke-case-*.out; do
            [ -e \"\$path\" ] && printf '%s\n' \"\$path\"
        done
    " > "$dest/artifacts.list" 2>/dev/null || true

    if [ -s "$dest/artifacts.list" ]; then
        while IFS= read -r artifact; do
            [ -n "$artifact" ] || continue
            docker cp "$CONTAINER:/tmp/$artifact" "$dest/$artifact" >/dev/null 2>&1 || true
        done < "$dest/artifacts.list"
    fi

    docker exec "$CONTAINER" sh -lc "
        printf 'container=%s\n' '$CONTAINER'
        printf 'workdir=%s\n' '$WORKDIR'
        printf 'service=%s\n' '$SERVICE'
        date -u '+completed_at=%Y-%m-%dT%H:%M:%SZ'
    " > "$dest/metadata.env" 2>/dev/null || true

    bundle="$dest/$RUN_NAME.txt"
    {
        echo "Native PAM Ubuntu Smoke"
        echo "======================="
        echo
        echo "[metadata]"
        if [ -f "$dest/metadata.env" ]; then
            cat "$dest/metadata.env"
        fi
        echo
        echo "[run.log]"
        if [ -f "$dest/run.log" ]; then
            cat "$dest/run.log"
        fi
        echo
        echo "[syslog]"
        if [ -f "$dest/native-pam-smoke-syslog" ]; then
            cat "$dest/native-pam-smoke-syslog"
        fi
        echo
        echo "[case output]"
        for file in "$dest"/native-pam-smoke-case-*.out; do
            [ -e "$file" ] || continue
            echo
            echo "--- $(basename "$file") ---"
            cat "$file"
        done
        echo
        echo "[artifacts]"
        if [ -f "$dest/artifacts.list" ]; then
            cat "$dest/artifacts.list"
        fi
    } > "$bundle"
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
        --exclude=.test-output \
        --exclude=build \
        --exclude=dist \
        --exclude=target \
        -C "$ROOT" \
        -cf - . \
        | docker exec -i "$CONTAINER" tar -C "$WORKDIR" -xf -
}

build_package_checker_for_container() {
    container_arch="$(docker exec "$CONTAINER" sh -lc "dpkg --print-architecture 2>/dev/null || uname -m")"
    case "$container_arch" in
        amd64|x86_64)
            goarch=amd64
            goamd64="${GOAMD64:-v1}"
            ;;
        arm64|aarch64)
            goarch=arm64
            goamd64=""
            ;;
        *)
            fail "unsupported native PAM package smoke architecture: $container_arch"
            ;;
    esac

    mkdir -p "$RUN_DIR/prebuilt"
    (
        cd "$ROOT"
        CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOAMD64="$goamd64" \
            go build -trimpath \
            -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=native-smoke" \
            -o "$RUN_DIR/prebuilt/pwned-check" ./cmd/pwned-check
    )
    docker cp "$RUN_DIR/prebuilt/pwned-check" "$CONTAINER:/tmp/native-pam-package-pwned-check"
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
    docker exec "$CONTAINER" sh -lc "cc -Wall -Wextra -Werror -o /usr/local/bin/native-pam-smoke-client /tmp/native-pam-smoke-client.c -lpam"

    docker exec -i "$CONTAINER" sh -c "cat > /tmp/native-pam-smoke-syslog-capture.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <output>\n", argv[0]);
    return 2;
  }

  signal(SIGTERM, SIG_DFL);
  unlink("/dev/log");

  int sock = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (sock < 0) {
    perror("socket");
    return 2;
  }

  struct sockaddr_un addr;
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, "/dev/log", sizeof(addr.sun_path) - 1);
  if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    perror("bind");
    return 2;
  }
  chmod("/dev/log", 0666);

  int out = open(argv[1], O_CREAT | O_WRONLY | O_APPEND, 0644);
  if (out < 0) {
    perror("open");
    return 2;
  }

  char buffer[4096];
  for (;;) {
    ssize_t n = recv(sock, buffer, sizeof(buffer) - 1, 0);
    if (n < 0) {
      if (errno == EINTR) {
        continue;
      }
      perror("recv");
      return 2;
    }
    buffer[n] = '\0';
    write(out, buffer, (size_t)n);
    write(out, "\n", 1);
    fsync(out);
  }
}
EOF
    docker exec "$CONTAINER" sh -lc "cc -Wall -Wextra -Werror -o /usr/local/bin/native-pam-smoke-syslog-capture /tmp/native-pam-smoke-syslog-capture.c"

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
    prepare_output_dir
    build_package_checker_for_container
    sync_repo
    write_smoke_client

    set +e
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
        rm -f /tmp/native-pam-smoke-syslog /tmp/native-pam-smoke-case-*.out /dev/log
        /usr/local/bin/native-pam-smoke-syslog-capture /tmp/native-pam-smoke-syslog &
        syslog_capture_pid=\"\$!\"
        common_password_backup=/tmp/native-pam-common-password.before
        pam_state_backup=/tmp/native-pam-var-lib-pam.before
        cleanup_syslog_capture() {
          kill \"\$syslog_capture_pid\" >/dev/null 2>&1 || true
          wait \"\$syslog_capture_pid\" >/dev/null 2>&1 || true
        }
        cleanup_pam_state() {
          if [ -f \"\$common_password_backup\" ]; then
            cp \"\$common_password_backup\" /etc/pam.d/common-password || true
          fi
          if [ -d \"\$pam_state_backup\" ]; then
            rm -rf /var/lib/pam
            cp -a \"\$pam_state_backup\" /var/lib/pam || true
          fi
        }
        cleanup_smoke() {
          cleanup_pam_state
          cleanup_syslog_capture
        }
        trap cleanup_smoke EXIT INT TERM
        i=0
        while [ ! -S /dev/log ]; do
          i=\"\$((i + 1))\"
          if [ \"\$i\" -gt 50 ]; then
            echo 'Native PAM syslog capture did not create /dev/log' >&2
            exit 1
          fi
          sleep 0.1
        done

        cat > /usr/local/bin/native-pam-smoke-checker <<'CHECKER_EOF'
#!/bin/sh
set -eu
printf '%s' \"\$*\" >/tmp/native-pam-smoke-checker-argv
printf '%s' \"\${PWNED_CHECK_FAIL_CLOSED:-}\" >/tmp/native-pam-smoke-checker-fail-closed
printf '%s' \"\$\$\" >/tmp/native-pam-smoke-checker-pid
/usr/bin/env >/tmp/native-pam-smoke-checker-env
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
    trap '' TERM
    /bin/sleep 30
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
          want_message=\"\$6\"
          want_checker=\"\$7\"
          want_fail_closed=\"\$8\"

          printf '%s' \"\$mode\" >/tmp/native-pam-smoke-checker-mode
          rm -f /tmp/native-pam-smoke-checker-token \
            /tmp/native-pam-smoke-checker-argv \
            /tmp/native-pam-smoke-checker-fail-closed \
            /tmp/native-pam-smoke-checker-pid \
            /tmp/native-pam-smoke-checker-env
          write_service \"\$args\"

          set +e
          PWNED_CHECK_SHOULD_NOT_LEAK='secret' \
            PWNED_CHECK_NATIVE_SMOKE_TOKEN=\"\$token\" \
            /usr/local/bin/native-pam-smoke-client '$SERVICE' root \"\$token\" >/tmp/native-pam-smoke.out 2>&1
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

          if [ \"\$want_message\" != '-' ]; then
            if ! grep -F \"\$want_message\" /tmp/native-pam-smoke.out >/dev/null; then
              cat /tmp/native-pam-smoke.out >&2
              echo \"Native PAM case failed: \$name missing message: \$want_message\" >&2
              exit 1
            fi
          else
            if grep -F 'This password appears in a known breach corpus. Choose a different password.' /tmp/native-pam-smoke.out >/dev/null ||
               grep -F 'Password breach check failed. Try again later or contact your administrator.' /tmp/native-pam-smoke.out >/dev/null; then
              cat /tmp/native-pam-smoke.out >&2
              echo \"Native PAM case failed: \$name emitted unexpected conversation message\" >&2
              exit 1
            fi
          fi

          if [ \"\$want_checker\" = no ]; then
            if [ -f /tmp/native-pam-smoke-checker-token ]; then
              echo \"Native PAM case failed: \$name unexpectedly invoked checker\" >&2
              exit 1
            fi
          else
            if [ ! -f /tmp/native-pam-smoke-checker-argv ]; then
              echo \"Native PAM case failed: \$name did not invoke checker\" >&2
              exit 1
            fi
            checker_argv=\"\$(cat /tmp/native-pam-smoke-checker-argv)\"
            want_argv='--stdin'
            case \" \$args \" in
              *' min_count=42 '*) want_argv='--stdin --min-count 42' ;;
            esac
            if [ \"\$checker_argv\" != \"\$want_argv\" ]; then
              echo \"Native PAM case failed: \$name checker argv=\$checker_argv want \$want_argv\" >&2
              exit 1
            fi
            checker_fail_closed=\"\$(cat /tmp/native-pam-smoke-checker-fail-closed)\"
            if [ \"\$checker_fail_closed\" != \"\$want_fail_closed\" ]; then
              echo \"Native PAM case failed: \$name fail_closed=\$checker_fail_closed want \$want_fail_closed\" >&2
              exit 1
            fi
            checker_env=\"\$(cat /tmp/native-pam-smoke-checker-env)\"
            if printf '%s' \"\$checker_env\" | grep -F 'PWNED_CHECK_NATIVE_SMOKE_TOKEN=' >/dev/null ||
               printf '%s' \"\$checker_env\" | grep -F 'PWNED_CHECK_SHOULD_NOT_LEAK=' >/dev/null ||
               printf '%s' \"\$checker_env\" | grep -F 'secret' >/dev/null; then
              echo \"Native PAM case failed: \$name leaked caller environment into checker\" >&2
              exit 1
            fi
            if [ \"\$mode\" != sleep ]; then
              received=\"\$(cat /tmp/native-pam-smoke-checker-token)\"
              if [ \"\$received\" != \"\$token\" ]; then
                echo \"Native PAM case failed: \$name checker token mismatch\" >&2
                exit 1
              fi
            else
              checker_pid=\"\$(cat /tmp/native-pam-smoke-checker-pid)\"
              if kill -0 \"\$checker_pid\" 2>/dev/null; then
                echo \"Native PAM case failed: \$name left checker process alive\" >&2
                exit 1
              fi
            fi
            if grep -F \"\$token\" /tmp/native-pam-smoke.out >/dev/null; then
              cat /tmp/native-pam-smoke.out >&2
              echo \"Native PAM case failed: \$name leaked token to PAM output\" >&2
              exit 1
            fi
          fi

          case_artifact=\"\$(printf '%s' \"\$name\" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')\"
          cp /tmp/native-pam-smoke.out \"/tmp/native-pam-smoke-case-\$case_artifact.out\"
          echo \"Native PAM case passed: \$name\"
        }

        test -f \"\$module_dir/pam_pwned_check.so\"
        ldd \"\$module_dir/pam_pwned_check.so\"

        pwned_message='This password appears in a known breach corpus. Choose a different password.'
        failure_message='Password breach check failed. Try again later or contact your administrator.'

        run_case 'clean allowed' clean CleanCandidate123 'fail_open' allow '-' yes false
        run_case 'pwned rejected' pwned PwnedCandidate123 'fail_open' reject \"\$pwned_message\" yes false
        run_case 'provider unavailable fail-open allowed' provider ProviderOpen123 'fail_open' allow '-' yes false
        run_case 'provider unavailable fail-closed rejected' provider ProviderClosed123 'fail_closed' reject \"\$failure_message\" yes true
        run_case 'checker config rejected' config ConfigCandidate123 'fail_open' reject \"\$failure_message\" yes false
        run_case 'checker timeout rejected' sleep TimeoutCandidate123 'fail_open' reject \"\$failure_message\" yes false
        run_case 'dry-run pwned allowed' pwned DryRunCandidate123 'fail_open dry_run debug' allow '-' yes false
        run_case 'min-count forwarded' clean MinCountCandidate123 'fail_open min_count=42 debug' allow '-' yes false
        run_case 'invalid module arg rejected' clean InvalidArgCandidate123 'fail_clsoed' reject \"\$failure_message\" no ''

        assert_log() {
          if ! grep -F \"\$1\" /tmp/native-pam-smoke-syslog >/dev/null; then
            cat /tmp/native-pam-smoke-syslog >&2
            echo \"Native PAM smoke missing syslog event: \$1\" >&2
            exit 1
          fi
        }

        assert_log 'event=pam_module_result result=allow'
        assert_log 'event=pam_module_result result=reject reason=pwned'
        assert_log 'event=pam_module_failure reason=checker_config code=2'
        assert_log 'event=pam_module_failure reason=timeout timeout=1s'
        assert_log 'event=pam_module_result result=allow mode=dry_run would=reject reason=pwned'
        assert_log 'event=pam_module_config timeout=1s fail_policy=fail_open dry_run=true'
        assert_log 'event=pam_module_config timeout=1s min_count=42 fail_policy=fail_open dry_run=false'

        if grep -F 'CleanCandidate123' /tmp/native-pam-smoke-syslog >/dev/null ||
           grep -F 'PwnedCandidate123' /tmp/native-pam-smoke-syslog >/dev/null ||
           grep -F 'DryRunCandidate123' /tmp/native-pam-smoke-syslog >/dev/null ||
           grep -F 'MinCountCandidate123' /tmp/native-pam-smoke-syslog >/dev/null ||
           grep -F '/usr/local/bin/native-pam-smoke-checker' /tmp/native-pam-smoke-syslog >/dev/null; then
          cat /tmp/native-pam-smoke-syslog >&2
          echo 'Native PAM smoke leaked candidate or checker path to syslog' >&2
          exit 1
        fi

        package_out=/tmp/native-pam-debian-package
        package_root=/tmp/native-pam-debian-package-root
        rm -rf \"\$package_out\" \"\$package_root\"
        mkdir -p \"\$package_out\" \"\$package_root\"
        package_basename=\"\$(./scripts/package-native-pam-debian-artifact.sh --version native-smoke --output-dir \"\$package_out\" --pwned-check-bin /tmp/native-pam-package-pwned-check)\"
        package_path=\"\$package_out/\$package_basename.tar.gz\"
        test -f \"\$package_path\"
        test -f \"\$package_path.sha256\"
        tar -tzf \"\$package_path\" | grep -F \"/rootfs/lib/\$(gcc -print-multiarch)/security/pam_pwned_check.so\" >/dev/null
        tar -tzf \"\$package_path\" | grep -F '/rootfs/usr/bin/pwned-check' >/dev/null
        tar -tzf \"\$package_path\" | grep -F '/rootfs/usr/share/pam-configs/pwned-check' >/dev/null
        rm -rf \"/tmp/\$package_basename\"
        tar -xzf \"\$package_path\" -C /tmp
        (cd \"/tmp/\$package_basename\" && DESTDIR=\"\$package_root\" ./install.sh)
        test -x \"\$package_root/usr/bin/pwned-check\"
        test -x \"\$package_root/lib/\$(gcc -print-multiarch)/security/pam_pwned_check.so\"
        grep -F 'Default: no' \"\$package_root/usr/share/pam-configs/pwned-check\" >/dev/null
        grep -F 'dry_run' \"\$package_root/usr/share/pam-configs/pwned-check\" >/dev/null
        \"\$package_root/usr/bin/pwned-check\" --version >/dev/null

        cp /etc/pam.d/common-password \"\$common_password_backup\"
        rm -rf \"\$pam_state_backup\"
        cp -a /var/lib/pam \"\$pam_state_backup\"
        (cd \"/tmp/\$package_basename\" && ./install.sh)
        test -x /usr/bin/pwned-check
        test -x \"\$module_dir/pam_pwned_check.so\"
        test -f /usr/share/pam-configs/pwned-check
        DEBIAN_FRONTEND=noninteractive pam-auth-update --enable pwned-check --package
        grep -F 'pam_pwned_check.so checker=/usr/bin/pwned-check timeout=3 fail_open dry_run' /etc/pam.d/common-password >/dev/null
        echo 'Native PAM Debian pam-auth-update enable passed'
        DEBIAN_FRONTEND=noninteractive pam-auth-update --disable pwned-check --package
        if grep -F 'pam_pwned_check.so' /etc/pam.d/common-password >/dev/null; then
          cat /etc/pam.d/common-password >&2
          echo 'Native PAM Debian pam-auth-update rollback left module enabled' >&2
          exit 1
        fi
        cleanup_pam_state
        rm -f \"\$common_password_backup\"
        rm -rf \"\$pam_state_backup\"
        echo 'Native PAM Debian pam-auth-update rollback passed'
        echo \"Native PAM Debian package artifact passed: \$package_basename\"
    " > "$RUN_DIR/run.log" 2>&1
    status="$?"
    set -e
    cat "$OUTPUT_DIR/latest/run.log"
    capture_smoke_artifacts

    if [ "$status" -ne 0 ]; then
        echo "Native PAM Ubuntu smoke failed in persistent container: $CONTAINER" >&2
        echo "Captured smoke output in: $RUN_DIR" >&2
        echo "Latest smoke output link: $OUTPUT_DIR/latest" >&2
        echo "Combined text output: $RUN_DIR/$RUN_NAME.txt" >&2
        exit "$status"
    fi

    echo "Native PAM Ubuntu smoke passed in persistent container: $CONTAINER"
    echo "Captured smoke output in: $RUN_DIR"
    echo "Latest smoke output link: $OUTPUT_DIR/latest"
    echo "Combined text output: $RUN_DIR/$RUN_NAME.txt"
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
