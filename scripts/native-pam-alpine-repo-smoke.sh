#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-alpine-repo-smoke}"
HOST="codex-vm-alpine"
REPO_DIR="$ROOT/dist/alpine-repository"
REPO_URL=""
PUBLIC_KEY="$REPO_DIR/pwned-check-native-pam.rsa.pub"
PUBLIC_KEY_WAS_SET=0
PUBLIC_KEY_URL="https://phillipmcmahon.github.io/pwned-check/alpine/pwned-check-alpine-production.rsa.pub"
PUBLIC_KEY_NAME=""
REMOTE_DIR=""
PACKAGE_NAME="pwned-check-native-pam"

if capture_or_reexec "$OUTPUT_ROOT" "native-pam-alpine-repo-smoke" \
    "PWNED_CHECK_ALPINE_REPO_SMOKE_NO_CAPTURE" \
    "Native PAM Alpine repository smoke output" "$0" "$@"; then
    :
fi

usage() {
    cat <<'EOF'
Usage: scripts/native-pam-alpine-repo-smoke.sh [OPTIONS]

Run a repo-only Alpine Linux-PAM install smoke on the Alpine VM. The script
copies a prepared APK repository and public key to the target, configures apk
trust and repository source, installs pwned-check-native-pam, exercises
dry-run/enforce/disable helpers, removes the package, and verifies managed-file
cleanup.

The target VM does not need GitHub credentials or build tools.

Options:
  --host <ssh-host>       SSH host (default: codex-vm-alpine)
  --repo-dir <path>      Local Alpine repository directory
                          (default: dist/alpine-repository)
  --repo-url <url>       Published Alpine repository URL. When set, the VM
                          installs from this URL instead of a copied repo.
  --public-key <path>    Local RSA public key
                          (default: <repo-dir>/pwned-check-native-pam.rsa.pub)
  --public-key-url <url> Published public key URL used with --repo-url when
                          --public-key is not set
                          (default: project production Alpine RSA key)
  --remote-dir <path>    Remote temporary directory
  --help                 Show this help text

Environment:
  PWNED_CHECK_TEST_OUTPUT_DIR  Output root for combined smoke logs
                               (default: .test-output/native-pam-alpine-repo-smoke)
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            [ "$#" -ge 2 ] || fail "--host requires a value"
            HOST="$2"
            shift 2
            ;;
        --repo-dir)
            [ "$#" -ge 2 ] || fail "--repo-dir requires a value"
            REPO_DIR="$2"
            shift 2
            ;;
        --repo-url)
            [ "$#" -ge 2 ] || fail "--repo-url requires a value"
            REPO_URL="$2"
            shift 2
            ;;
        --public-key)
            [ "$#" -ge 2 ] || fail "--public-key requires a value"
            PUBLIC_KEY="$2"
            PUBLIC_KEY_WAS_SET=1
            shift 2
            ;;
        --public-key-url)
            [ "$#" -ge 2 ] || fail "--public-key-url requires a value"
            PUBLIC_KEY_URL="$2"
            shift 2
            ;;
        --remote-dir)
            [ "$#" -ge 2 ] || fail "--remote-dir requires a value"
            REMOTE_DIR="$2"
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

if [ -z "$REPO_URL" ]; then
    [ -d "$REPO_DIR" ] || fail "repository directory does not exist: $REPO_DIR"
fi
if [ -n "$REPO_URL" ] && [ "$PUBLIC_KEY_WAS_SET" -eq 0 ]; then
    require_command curl
    PUBLIC_KEY_NAME="$(basename "$PUBLIC_KEY_URL")"
    PUBLIC_KEY="$(mktemp "${TMPDIR:-/tmp}/pwned-check-alpine-key.XXXXXX")"
    curl -fsSL "$PUBLIC_KEY_URL" > "$PUBLIC_KEY" || fail "failed to download public key: $PUBLIC_KEY_URL"
fi
[ -f "$PUBLIC_KEY" ] || fail "public key file does not exist: $PUBLIC_KEY"
if [ -z "$PUBLIC_KEY_NAME" ]; then
    PUBLIC_KEY_NAME="$(basename "$PUBLIC_KEY")"
fi

require_command ssh
require_command scp

if [ -z "$REMOTE_DIR" ]; then
    REMOTE_DIR="/tmp/pwned-check-alpine-repo-smoke-$(date +%Y%m%d%H%M%S)-$$"
fi

ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
if [ -z "$REPO_URL" ]; then
    scp -r "$REPO_DIR" "$HOST:$REMOTE_DIR/repo"
fi
scp "$PUBLIC_KEY" "$HOST:$REMOTE_DIR/$PUBLIC_KEY_NAME"

ssh "$HOST" "REMOTE_DIR='$REMOTE_DIR' REPO_URL='$REPO_URL' PACKAGE_NAME='$PACKAGE_NAME' PUBLIC_KEY_NAME='$PUBLIC_KEY_NAME' sh -s" <<'EOF'
set -eu

PATH="/usr/sbin:/sbin:$PATH"
export PATH

fail() {
    echo "Error: $*" >&2
    exit 1
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n "$@"
    else
        doas "$@"
    fi
}

cleanup() {
    set +e
    as_root pwned-check-pam-disable >/dev/null 2>&1
    as_root apk del "$PACKAGE_NAME" >/dev/null 2>&1
    if [ -n "${REPOSITORIES_BACKUP:-}" ] && [ -f "$REPOSITORIES_BACKUP" ]; then
        as_root cp "$REPOSITORIES_BACKUP" /etc/apk/repositories
    fi
    as_root rm -f "/etc/apk/keys/$PUBLIC_KEY_NAME"
    as_root rm -rf "$REMOTE_DIR"
}
trap cleanup EXIT INT TERM

[ -r /etc/os-release ] || fail "/etc/os-release not readable"
OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
[ "$OS_ID" = "alpine" ] || fail "Alpine repo smoke supports Alpine only, got ID=${OS_ID:-unknown}"
command -v apk >/dev/null 2>&1 || fail "apk is required on target"
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || command -v doas >/dev/null 2>&1 || fail "sudo or doas is required for non-root smoke"
fi

arch="$(apk --print-arch)"
if [ -z "$REPO_URL" ]; then
    [ -f "$REMOTE_DIR/repo/$arch/APKINDEX.tar.gz" ] || fail "repository missing APKINDEX for target arch: $arch"
fi

as_root pwned-check-pam-disable >/dev/null 2>&1 || true
as_root apk del "$PACKAGE_NAME" >/dev/null 2>&1 || true
as_root install -d -m 0755 /etc/apk/keys
as_root install -m 0644 "$REMOTE_DIR/$PUBLIC_KEY_NAME" "/etc/apk/keys/$PUBLIC_KEY_NAME"

REPOSITORIES_BACKUP="$(mktemp)"
as_root cp /etc/apk/repositories "$REPOSITORIES_BACKUP"
if [ -n "$REPO_URL" ]; then
    repo_source="$REPO_URL"
else
    repo_source="file://$REMOTE_DIR/repo"
fi
as_root sh -c "printf '%s\n' '$repo_source' >> /etc/apk/repositories"

as_root apk update
as_root apk add "$PACKAGE_NAME"

apk info -e "$PACKAGE_NAME" >/dev/null
command -v pwned-check >/dev/null || fail "pwned-check command missing after repo install"
command -v pwned-check-pam-enable-dry-run >/dev/null || fail "dry-run helper missing after repo install"
command -v pwned-check-pam-enable-enforce >/dev/null || fail "enforce helper missing after repo install"
command -v pwned-check-pam-disable >/dev/null || fail "disable helper missing after repo install"
pwned-check --version >/dev/null

service="/etc/pam.d/pwned-check-repo-smoke"
state_file="$REMOTE_DIR/manual-pam-last-backup"
backup_dir="$REMOTE_DIR/pam-backups"
[ ! -e "$service" ] || fail "test PAM service already exists: $service"
as_root sh -c "printf '%s\n' 'password required pam_unix.so' > '$service'"

as_root env PWNED_CHECK_PAM_SERVICE_PATH="$service" PWNED_CHECK_STATE_FILE="$state_file" PWNED_CHECK_BACKUP_DIR="$backup_dir" pwned-check-pam-enable-dry-run
grep -F 'pam_pwned_check.so' "$service" >/dev/null || fail "dry-run helper did not update test service"
grep -F 'dry_run' "$service" >/dev/null || fail "dry-run helper did not configure dry_run"

as_root env PWNED_CHECK_PAM_SERVICE_PATH="$service" PWNED_CHECK_STATE_FILE="$state_file" PWNED_CHECK_BACKUP_DIR="$backup_dir" pwned-check-pam-enable-enforce
grep -F 'pam_pwned_check.so' "$service" >/dev/null || fail "enforce helper removed pam_pwned_check"
if grep -F 'pam_pwned_check.so' "$service" | grep -F 'dry_run' >/dev/null; then
    fail "enforce helper left dry_run in test service"
fi

as_root env PWNED_CHECK_PAM_SERVICE_PATH="$service" PWNED_CHECK_STATE_FILE="$state_file" pwned-check-pam-disable
if grep -F 'pam_pwned_check.so' "$service" >/dev/null; then
    fail "disable helper left pam_pwned_check in test service"
fi
as_root rm -f "$service"

as_root apk del "$PACKAGE_NAME"
if apk info -e "$PACKAGE_NAME" >/dev/null 2>&1; then
    fail "$PACKAGE_NAME is still installed after removal"
fi
for path in /usr/bin/pwned-check /usr/sbin/pwned-check-pam-enable-dry-run /usr/sbin/pwned-check-pam-enable-enforce /usr/sbin/pwned-check-pam-disable /usr/lib/security/pam_pwned_check.so /lib/security/pam_pwned_check.so /usr/share/pwned-check/manual-pam; do
    [ ! -e "$path" ] || fail "package-managed path still exists after removal: $path"
done

trap - EXIT INT TERM
cleanup
echo "Native PAM Alpine repository smoke passed on $arch"
EOF
