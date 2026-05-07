#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-arch-repo-smoke}"
HOST="codex-vm-arch"
REPO_DIR="$ROOT/dist/arch-repository"
REPO_URL=""
PUBLIC_KEY="$REPO_DIR/pwned-check-native-pam.asc"
PUBLIC_KEY_WAS_SET=0
PUBLIC_KEY_URL="https://phillipmcmahon.github.io/pwned-check/pwned-check-openpgp-production.asc"
REMOTE_DIR=""
REPO_NAME="pwned-check"
PACKAGE_NAME="pwned-check-native-pam"
EXPECTED_VERSION="${PWNED_CHECK_EXPECTED_PACKAGE_VERSION:-}"

if capture_or_reexec "$OUTPUT_ROOT" "native-pam-arch-repo-smoke" \
    "PWNED_CHECK_ARCH_REPO_SMOKE_NO_CAPTURE" \
    "Native PAM Arch repository smoke output" "$0" "$@"; then
    :
fi

usage() {
    cat <<'EOF'
Usage: scripts/native-pam-arch-repo-smoke.sh [OPTIONS]

Run a repo-only Arch Linux install smoke on the Arch VM. The script copies a
prepared signed pacman repository and public key to the target, configures
pacman trust and repository source, installs pwned-check-native-pam with
pacman -S, exercises dry-run/enforce/disable helpers, removes the package, and
verifies managed-file cleanup.

The target VM does not need GitHub credentials or build tools.

Options:
  --host <ssh-host>       SSH host (default: codex-vm-arch)
  --repo-dir <path>      Local Arch repository directory
                          (default: dist/arch-repository)
  --repo-url <url>       Published Arch repository URL. When set, the VM
                          installs from this URL instead of a copied repo.
  --public-key <path>    Local armored GPG public key
                          (default: <repo-dir>/pwned-check-native-pam.asc)
  --public-key-url <url> Published public key URL used with --repo-url when
                          --public-key is not set
                          (default: project production OpenPGP key)
  --repo-name <name>     pacman repository name (default: pwned-check)
  --expected-version <v> Assert installed pwned-check reports this version
                          (or PWNED_CHECK_EXPECTED_PACKAGE_VERSION)
  --remote-dir <path>    Remote temporary directory
  --help                 Show this help text

Environment:
  PWNED_CHECK_TEST_OUTPUT_DIR  Output root for combined smoke logs
                               (default: .test-output/native-pam-arch-repo-smoke)
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
        --repo-name)
            [ "$#" -ge 2 ] || fail "--repo-name requires a value"
            REPO_NAME="$2"
            shift 2
            ;;
        --expected-version)
            [ "$#" -ge 2 ] || fail "--expected-version requires a value"
            EXPECTED_VERSION="$2"
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
    PUBLIC_KEY="$(mktemp "${TMPDIR:-/tmp}/pwned-check-arch-key.XXXXXX")"
    curl -fsSL "$PUBLIC_KEY_URL" > "$PUBLIC_KEY" || fail "failed to download public key: $PUBLIC_KEY_URL"
fi
[ -f "$PUBLIC_KEY" ] || fail "public key file does not exist: $PUBLIC_KEY"

require_command ssh
require_command scp

if [ -z "$REMOTE_DIR" ]; then
    REMOTE_DIR="/tmp/pwned-check-arch-repo-smoke-$(date +%Y%m%d%H%M%S)-$$"
fi

ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
if [ -z "$REPO_URL" ]; then
    scp -r "$REPO_DIR" "$HOST:$REMOTE_DIR/repo"
fi
scp "$PUBLIC_KEY" "$HOST:$REMOTE_DIR/pwned-check-native-pam.asc"

ssh "$HOST" "REMOTE_DIR='$REMOTE_DIR' REPO_URL='$REPO_URL' REPO_NAME='$REPO_NAME' PACKAGE_NAME='$PACKAGE_NAME' EXPECTED_VERSION='$EXPECTED_VERSION' sh -s" <<'EOF'
set -eu

PATH="/usr/sbin:/sbin:$PATH"
export PATH

fail() {
    echo "Error: $*" >&2
    exit 1
}

assert_module_defaults() {
    line="$1"
    mode="$2"
    printf '%s\n' "$line" | grep -F 'pam_pwned_check.so' >/dev/null || fail "$mode line missing pam_pwned_check.so"
    printf '%s\n' "$line" | grep -F 'checker=/usr/bin/pwned-check' >/dev/null || fail "$mode line missing checker=/usr/bin/pwned-check"
    printf '%s\n' "$line" | grep -F 'timeout=3' >/dev/null || fail "$mode line missing timeout=3"
    printf '%s\n' "$line" | grep -F 'fail_open' >/dev/null || fail "$mode line missing fail_open"
    case "$mode" in
        dry-run)
            printf '%s\n' "$line" | grep -F 'dry_run' >/dev/null || fail "$mode line missing dry_run"
            ;;
        enforce)
            if printf '%s\n' "$line" | grep -F 'dry_run' >/dev/null; then
                fail "$mode line should not include dry_run"
            fi
            ;;
        *) fail "unknown module default assertion mode: $mode" ;;
    esac
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

cleanup() {
    set +e
    as_root pwned-check-pam-disable >/dev/null 2>&1
    as_root pacman -Rns --noconfirm "$PACKAGE_NAME" >/dev/null 2>&1
    as_root rm -f /var/cache/pacman/pkg/pwned-check-native-pam-* >/dev/null 2>&1
    if [ -n "${PACMAN_CONF_BACKUP:-}" ] && [ -f "$PACMAN_CONF_BACKUP" ]; then
        as_root cp "$PACMAN_CONF_BACKUP" /etc/pacman.conf
    fi
    if [ -n "${KEY_FINGERPRINT:-}" ]; then
        as_root pacman-key --delete "$KEY_FINGERPRINT" >/dev/null 2>&1
    fi
    as_root rm -rf "$REMOTE_DIR"
}
trap cleanup EXIT INT TERM

[ -r /etc/os-release ] || fail "/etc/os-release not readable"
OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
[ "$OS_ID" = "arch" ] || fail "Arch repo smoke supports Arch only, got ID=${OS_ID:-unknown}"
command -v pacman >/dev/null 2>&1 || fail "pacman is required on target"
command -v pacman-key >/dev/null 2>&1 || fail "pacman-key is required on target"
command -v gpg >/dev/null 2>&1 || fail "gpg is required on target"
if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || fail "sudo is required for non-root smoke"
fi

machine="$(uname -m)"
case "$machine" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) fail "unsupported Arch machine architecture: $machine" ;;
esac
if [ -z "$REPO_URL" ]; then
    [ -f "$REMOTE_DIR/repo/$arch/$REPO_NAME.db" ] || fail "repository missing database for target arch: $arch"
fi

KEY_FINGERPRINT="$(gpg --show-keys --with-colons "$REMOTE_DIR/pwned-check-native-pam.asc" | awk -F: '$1 == "fpr" {print $10; exit}')"
[ -n "$KEY_FINGERPRINT" ] || fail "could not determine repository signing key fingerprint"

as_root pwned-check-pam-disable >/dev/null 2>&1 || true
as_root pacman -Rns --noconfirm "$PACKAGE_NAME" >/dev/null 2>&1 || true
as_root rm -f /var/cache/pacman/pkg/pwned-check-native-pam-* >/dev/null 2>&1 || true
as_root pacman-key --add "$REMOTE_DIR/pwned-check-native-pam.asc"
as_root pacman-key --lsign-key "$KEY_FINGERPRINT"

PACMAN_CONF_BACKUP="$(mktemp)"
as_root cp /etc/pacman.conf "$PACMAN_CONF_BACKUP"
if [ -n "$REPO_URL" ]; then
    repo_source="$REPO_URL/$arch"
else
    repo_source="file://$REMOTE_DIR/repo/$arch"
fi
as_root sh -c "cat >> /etc/pacman.conf" <<CONF

[$REPO_NAME]
SigLevel = Required DatabaseRequired
Server = $repo_source
CONF

as_root pacman -Sy --noconfirm "$PACKAGE_NAME"
pacman -Q "$PACKAGE_NAME" >/dev/null
[ -x /usr/bin/pwned-check ] || fail "pwned-check command missing after repo install"
[ -f /usr/lib/security/pam_pwned_check.so ] || fail "PAM module missing after repo install"
[ "$(stat -c '%a' /usr/lib/security/pam_pwned_check.so)" = "644" ] || fail "PAM module should be installed mode 0644"
[ "$(readlink -f "$(command -v pwned-check-pam-enable-dry-run)")" = "/usr/bin/pwned-check-pam-enable-dry-run" ] || fail "dry-run helper installed outside /usr/bin"
[ "$(readlink -f "$(command -v pwned-check-pam-enable-enforce)")" = "/usr/bin/pwned-check-pam-enable-enforce" ] || fail "enforce helper installed outside /usr/bin"
[ "$(readlink -f "$(command -v pwned-check-pam-disable)")" = "/usr/bin/pwned-check-pam-disable" ] || fail "disable helper installed outside /usr/bin"
actual_version="$(/usr/bin/pwned-check --version | awk '{print $2}')"
if [ -n "$EXPECTED_VERSION" ] && [ "$actual_version" != "$EXPECTED_VERSION" ]; then
    fail "installed pwned-check version $actual_version, expected $EXPECTED_VERSION"
fi

service="/etc/pam.d/pwned-check-repo-smoke"
state_file="$REMOTE_DIR/service-pam-last-backup"
backup_dir="$REMOTE_DIR/pam-backups"
[ ! -e "$service" ] || fail "test PAM service already exists: $service"
as_root sh -c "printf '%s\n' 'password required pam_unix.so' > '$service'"

as_root env PWNED_CHECK_PAM_SERVICE_PATH="$service" PWNED_CHECK_STATE_FILE="$state_file" PWNED_CHECK_BACKUP_DIR="$backup_dir" pwned-check-pam-enable-dry-run
dry_run_line="$(grep -F 'pam_pwned_check.so' "$service" || true)"
[ -n "$dry_run_line" ] || fail "dry-run helper did not update test service"
assert_module_defaults "$dry_run_line" dry-run

as_root env PWNED_CHECK_PAM_SERVICE_PATH="$service" PWNED_CHECK_STATE_FILE="$state_file" PWNED_CHECK_BACKUP_DIR="$backup_dir" pwned-check-pam-enable-enforce
enforce_line="$(grep -F 'pam_pwned_check.so' "$service" || true)"
[ -n "$enforce_line" ] || fail "enforce helper removed pam_pwned_check"
assert_module_defaults "$enforce_line" enforce

as_root env PWNED_CHECK_PAM_SERVICE_PATH="$service" PWNED_CHECK_STATE_FILE="$state_file" pwned-check-pam-disable
if grep -F 'pam_pwned_check.so' "$service" >/dev/null; then
    fail "disable helper left pam_pwned_check in test service"
fi
as_root rm -f "$service"

as_root pacman -Rns --noconfirm "$PACKAGE_NAME"
if pacman -Q "$PACKAGE_NAME" >/dev/null 2>&1; then
    fail "$PACKAGE_NAME is still installed after removal"
fi
for path in /usr/bin/pwned-check /usr/bin/pwned-check-pam-enable-dry-run /usr/bin/pwned-check-pam-enable-enforce /usr/bin/pwned-check-pam-disable /usr/lib/security/pam_pwned_check.so /usr/share/pwned-check/service-pam; do
    [ ! -e "$path" ] || fail "package-managed path still exists after removal: $path"
done

trap - EXIT INT TERM
cleanup
echo "Native PAM Arch repository smoke passed on $arch"
EOF
