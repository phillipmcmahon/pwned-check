#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-apt-repo-smoke}"
HOST=""
REPO_DIR="$ROOT/dist/apt-repository"
REPO_URL=""
PUBLIC_KEY="$REPO_DIR/pwned-check-archive-key.asc"
SUITE="stable"
COMPONENT="main"
REMOTE_DIR=""
PACKAGE_NAME="pwned-check-native-pam"

if [ "${PWNED_CHECK_APT_REPO_SMOKE_NO_CAPTURE:-}" != "1" ]; then
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    run_dir="$OUTPUT_ROOT/$timestamp-native-pam-apt-repo-smoke"
    mkdir -p "$run_dir"
    log_file="$run_dir/$timestamp-native-pam-apt-repo-smoke.txt"
    rc_file="$run_dir/exit-code"
    (
        set +e
        PWNED_CHECK_APT_REPO_SMOKE_NO_CAPTURE=1 "$0" "$@"
        rc=$?
        printf '%s\n' "$rc" > "$rc_file"
        exit "$rc"
    ) 2>&1 | tee "$log_file"
    rc="$(cat "$rc_file")"
    ln -sfn "$run_dir" "$OUTPUT_ROOT/latest"
    printf 'Native PAM apt repository smoke output: %s\n' "$log_file"
    exit "$rc"
fi

usage() {
    cat <<'EOF'
Usage: scripts/native-pam-apt-repo-smoke.sh --host <ssh-host> [OPTIONS]

Run a repo-only apt install smoke on a Debian/Ubuntu VM. The script copies a
prepared apt repository and public key to the target, configures apt from those
files, installs pwned-check-native-pam, exercises dry-run/enforce/disable
helpers, removes the package, and verifies managed-file cleanup.

The target VM does not need GitHub credentials or build tools.

Options:
  --host <ssh-host>       SSH host, for example codex-vm-ubuntu
  --repo-dir <path>      Local apt repository directory
                          (default: dist/apt-repository)
  --repo-url <url>       Published apt repository URL. When set, the VM
                          installs from this URL instead of a copied repo.
  --public-key <path>    Local ASCII-armored repository public key
                          (default: <repo-dir>/pwned-check-archive-key.asc)
  --suite <name>         Apt suite/codename (default: stable)
  --component <name>     Apt component (default: main)
  --remote-dir <path>    Remote temporary directory
  --help                 Show this help text

Environment:
  PWNED_CHECK_TEST_OUTPUT_DIR  Output root for combined smoke logs
                               (default: .test-output/native-pam-apt-repo-smoke)
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
            shift 2
            ;;
        --suite)
            [ "$#" -ge 2 ] || fail "--suite requires a value"
            SUITE="$2"
            shift 2
            ;;
        --component)
            [ "$#" -ge 2 ] || fail "--component requires a value"
            COMPONENT="$2"
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

[ -n "$HOST" ] || fail "--host is required"
if [ -z "$REPO_URL" ]; then
    [ -d "$REPO_DIR" ] || fail "repository directory does not exist: $REPO_DIR"
    [ -f "$REPO_DIR/dists/$SUITE/InRelease" ] || fail "repository missing signed InRelease for suite $SUITE"
fi
[ -f "$PUBLIC_KEY" ] || fail "public key file does not exist: $PUBLIC_KEY"

require_command ssh
require_command scp

case "$SUITE" in
    *[!A-Za-z0-9._+-]*|'') fail "invalid apt suite: $SUITE" ;;
esac
case "$COMPONENT" in
    *[!A-Za-z0-9._+-]*|'') fail "invalid apt component: $COMPONENT" ;;
esac

if [ -z "$REMOTE_DIR" ]; then
    REMOTE_DIR="/tmp/pwned-check-apt-repo-smoke-$(date +%Y%m%d%H%M%S)-$$"
fi

ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
if [ -z "$REPO_URL" ]; then
    scp -r "$REPO_DIR" "$HOST:$REMOTE_DIR/repo"
fi
scp "$PUBLIC_KEY" "$HOST:$REMOTE_DIR/pwned-check-archive-key.asc"

ssh "$HOST" "REMOTE_DIR='$REMOTE_DIR' REPO_URL='$REPO_URL' SUITE='$SUITE' COMPONENT='$COMPONENT' PACKAGE_NAME='$PACKAGE_NAME' sh -s" <<'EOF'
set -eu

PATH="/usr/sbin:/sbin:$PATH"
export PATH

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found on target: $1"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

cleanup() {
    set +e
    as_root pwned-check-pam-disable >/dev/null 2>&1
    as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PACKAGE_NAME" >/dev/null 2>&1
    as_root rm -f /etc/apt/sources.list.d/pwned-check-native-pam.list
    as_root rm -f /etc/apt/keyrings/pwned-check-native-pam.asc
    as_root apt-get update >/dev/null 2>&1
    rm -rf "$REMOTE_DIR"
}
trap cleanup EXIT INT TERM

[ -r /etc/os-release ] || fail "/etc/os-release not readable"
OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
case "$OS_ID" in
    ubuntu|debian) ;;
    *) fail "apt repo smoke supports Debian/Ubuntu only, got ID=${OS_ID:-unknown}" ;;
esac

require_command apt-get
require_command apt-cache
require_command dpkg
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

as_root pwned-check-pam-disable >/dev/null 2>&1 || true
as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PACKAGE_NAME" >/dev/null 2>&1 || true
as_root rm -f /etc/apt/sources.list.d/pwned-check-native-pam.list
as_root install -d -m 0755 /etc/apt/keyrings
as_root install -m 0644 "$REMOTE_DIR/pwned-check-archive-key.asc" /etc/apt/keyrings/pwned-check-native-pam.asc

if [ -n "$REPO_URL" ]; then
    repo_source="$REPO_URL"
else
    repo_source="file:$REMOTE_DIR/repo"
fi
as_root sh -c "printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/pwned-check-native-pam.asc] $repo_source $SUITE $COMPONENT' > /etc/apt/sources.list.d/pwned-check-native-pam.list"

as_root apt-get update
apt-cache policy "$PACKAGE_NAME" | grep -F "$repo_source" >/dev/null || fail "apt policy did not discover $PACKAGE_NAME from repo"
as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$PACKAGE_NAME"

dpkg -s "$PACKAGE_NAME" >/dev/null
command -v pwned-check >/dev/null || fail "pwned-check command missing after repo install"
command -v pwned-check-pam-enable-dry-run >/dev/null || fail "dry-run helper missing after repo install"
command -v pwned-check-pam-enable-enforce >/dev/null || fail "enforce helper missing after repo install"
command -v pwned-check-pam-disable >/dev/null || fail "disable helper missing after repo install"
pwned-check --version >/dev/null

common_password=/etc/pam.d/common-password
before="$(mktemp)"
as_root cp "$common_password" "$before"

as_root pwned-check-pam-enable-dry-run
grep -F 'pam_pwned_check.so' "$common_password" >/dev/null || fail "dry-run helper did not enable pam_pwned_check"
grep -F 'dry_run' "$common_password" >/dev/null || fail "dry-run helper did not configure dry_run"

as_root pwned-check-pam-enable-enforce
grep -F 'pam_pwned_check.so' "$common_password" >/dev/null || fail "enforce helper removed pam_pwned_check"
if grep -F 'pam_pwned_check.so' "$common_password" | grep -F 'dry_run' >/dev/null; then
    fail "enforce helper left dry_run in common-password"
fi

as_root pwned-check-pam-disable
if grep -F 'pam_pwned_check.so' "$common_password" >/dev/null; then
    fail "disable helper left pam_pwned_check in common-password"
fi
cmp -s "$common_password" "$before" || fail "common-password did not return to pre-smoke state"
rm -f "$before"

as_root env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$PACKAGE_NAME"
if dpkg -s "$PACKAGE_NAME" >/dev/null 2>&1; then
    fail "$PACKAGE_NAME is still installed after purge"
fi
for path in /usr/bin/pwned-check /usr/sbin/pwned-check-pam-enable-dry-run /usr/sbin/pwned-check-pam-enable-enforce /usr/sbin/pwned-check-pam-disable /usr/share/pam-configs/pwned-check; do
    [ ! -e "$path" ] || fail "package-managed path still exists after purge: $path"
done

trap - EXIT INT TERM
cleanup
echo "Native PAM apt repository smoke passed on $OS_ID"
EOF
