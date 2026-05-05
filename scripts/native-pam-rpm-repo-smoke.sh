#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-rpm-repo-smoke}"
HOST=""
REPO_DIR="$ROOT/dist/rpm-repository"
REPO_URL=""
PUBLIC_KEY="$REPO_DIR/RPM-GPG-KEY-pwned-check-native-pam.asc"
PUBLIC_KEY_WAS_SET=0
PUBLIC_KEY_URL="https://phillipmcmahon.github.io/pwned-check/pwned-check-openpgp-production.asc"
REMOTE_DIR=""
PACKAGE_NAME="pwned-check-native-pam"

if capture_or_reexec "$OUTPUT_ROOT" "native-pam-rpm-repo-smoke" \
    "PWNED_CHECK_RPM_REPO_SMOKE_NO_CAPTURE" \
    "Native PAM RPM repository smoke output" "$0" "$@"; then
    :
fi

usage() {
    cat <<'EOF'
Usage: scripts/native-pam-rpm-repo-smoke.sh --host <ssh-host> [OPTIONS]

Run a repo-only RPM-family install smoke on a Fedora/Rocky VM. The script
copies a prepared repository and public key to the target, configures dnf/yum
with package and repository metadata signature checks, installs
pwned-check-native-pam, exercises dry-run/enforce/disable helpers, removes the
package, and verifies managed-file cleanup.

The target VM does not need GitHub credentials or build tools.

Options:
  --host <ssh-host>       SSH host, for example codex-vm-fedora
  --repo-dir <path>      Local RPM repository directory
                          (default: dist/rpm-repository)
  --repo-url <url>       Published RPM repository URL. When set, the VM
                          installs from this URL instead of a copied repo.
  --public-key <path>    Local ASCII-armored RPM public key
                          (default: <repo-dir>/RPM-GPG-KEY-pwned-check-native-pam.asc)
  --public-key-url <url> Published public key URL used with --repo-url when
                          --public-key is not set
                          (default: project production OpenPGP key)
  --remote-dir <path>    Remote temporary directory
  --help                 Show this help text

Environment:
  PWNED_CHECK_TEST_OUTPUT_DIR  Output root for combined smoke logs
                               (default: .test-output/native-pam-rpm-repo-smoke)
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

[ -n "$HOST" ] || fail "--host is required"
if [ -z "$REPO_URL" ]; then
    [ -d "$REPO_DIR" ] || fail "repository directory does not exist: $REPO_DIR"
    [ -f "$REPO_DIR/repodata/repomd.xml" ] || fail "repository missing repomd.xml"
    [ -f "$REPO_DIR/repodata/repomd.xml.asc" ] || fail "repository missing signed repomd.xml.asc"
fi
if [ -n "$REPO_URL" ] && [ "$PUBLIC_KEY_WAS_SET" -eq 0 ]; then
    require_command curl
    PUBLIC_KEY="$(mktemp "${TMPDIR:-/tmp}/pwned-check-rpm-key.XXXXXX")"
    curl -fsSL "$PUBLIC_KEY_URL" > "$PUBLIC_KEY" || fail "failed to download public key: $PUBLIC_KEY_URL"
fi
[ -f "$PUBLIC_KEY" ] || fail "public key file does not exist: $PUBLIC_KEY"

require_command ssh
require_command scp

if [ -z "$REMOTE_DIR" ]; then
    REMOTE_DIR="/tmp/pwned-check-rpm-repo-smoke-$(date +%Y%m%d%H%M%S)-$$"
fi

ssh "$HOST" "rm -rf '$REMOTE_DIR' && mkdir -p '$REMOTE_DIR'"
if [ -z "$REPO_URL" ]; then
    scp -r "$REPO_DIR" "$HOST:$REMOTE_DIR/repo"
fi
scp "$PUBLIC_KEY" "$HOST:$REMOTE_DIR/RPM-GPG-KEY-pwned-check-native-pam.asc"

ssh "$HOST" "REMOTE_DIR='$REMOTE_DIR' REPO_URL='$REPO_URL' PACKAGE_NAME='$PACKAGE_NAME' sh -s" <<'EOF'
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

pkg_tool() {
    as_root "$PKG_TOOL" -y "$@" </dev/null
}

cleanup() {
    set +e
    as_root pwned-check-pam-disable >/dev/null 2>&1
    if command -v dnf >/dev/null 2>&1; then
        as_root dnf -y remove "$PACKAGE_NAME" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        as_root yum -y remove "$PACKAGE_NAME" >/dev/null 2>&1
    else
        as_root rpm -e "$PACKAGE_NAME" >/dev/null 2>&1
    fi
    as_root rm -f /etc/yum.repos.d/pwned-check-native-pam.repo
    as_root rm -f /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
    rm -rf "$REMOTE_DIR"
}
trap cleanup EXIT INT TERM

[ -r /etc/os-release ] || fail "/etc/os-release not readable"
OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
OS_ID_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')"
case " $OS_ID $OS_ID_LIKE " in
    *" fedora "*|*" rhel "*|*" centos "*) ;;
    *) fail "RPM repo smoke supports Fedora/RHEL-family hosts only, got ID=${OS_ID:-unknown}" ;;
esac

require_command rpm
require_command authselect
if command -v dnf >/dev/null 2>&1; then
    PKG_TOOL=dnf
elif command -v yum >/dev/null 2>&1; then
    PKG_TOOL=yum
else
    fail "dnf or yum is required on target"
fi
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

as_root pwned-check-pam-disable >/dev/null 2>&1 || true
as_root "$PKG_TOOL" -y remove "$PACKAGE_NAME" >/dev/null 2>&1 || true
as_root rm -f /etc/yum.repos.d/pwned-check-native-pam.repo
as_root install -d -m 0755 /etc/pki/rpm-gpg
as_root install -m 0644 "$REMOTE_DIR/RPM-GPG-KEY-pwned-check-native-pam.asc" /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
as_root rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam

if [ -n "$REPO_URL" ]; then
    repo_source="$REPO_URL"
else
    repo_source="file://$REMOTE_DIR/repo"
fi
as_root sh -c "cat > /etc/yum.repos.d/pwned-check-native-pam.repo" <<REPO
[pwned-check-native-pam]
name=pwned-check native PAM repository
baseurl=$repo_source
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-pwned-check-native-pam
metadata_expire=0
REPO

as_root "$PKG_TOOL" clean all </dev/null
pkg_tool makecache --disablerepo='*' --enablerepo=pwned-check-native-pam
pkg_tool install --disablerepo='*' --enablerepo=pwned-check-native-pam "$PACKAGE_NAME"

rpm -q "$PACKAGE_NAME" >/dev/null
rpm -ql "$PACKAGE_NAME" | grep -F '/lib64/security/pam_pwned_check.so' >/dev/null || fail "package file list missing PAM module"
command -v pwned-check >/dev/null || fail "pwned-check command missing after repo install"
command -v pwned-check-pam-enable-dry-run >/dev/null || fail "dry-run helper missing after repo install"
command -v pwned-check-pam-enable-enforce >/dev/null || fail "enforce helper missing after repo install"
command -v pwned-check-pam-disable >/dev/null || fail "disable helper missing after repo install"
pwned-check --version >/dev/null

before="$(mktemp)"
authselect current -r > "$before" 2>/dev/null || true

as_root pwned-check-pam-enable-dry-run
authselect current -r | grep -F 'custom/pwned-check' >/dev/null || fail "dry-run helper did not select custom profile"
grep -R 'pam_pwned_check.so' /etc/authselect/custom/pwned-check >/dev/null || fail "dry-run helper did not add pam_pwned_check"
grep -R 'dry_run' /etc/authselect/custom/pwned-check >/dev/null || fail "dry-run helper did not configure dry_run"

as_root pwned-check-pam-enable-enforce
grep -R 'pam_pwned_check.so' /etc/authselect/custom/pwned-check >/dev/null || fail "enforce helper removed pam_pwned_check"
if grep -R 'pam_pwned_check.so' /etc/authselect/custom/pwned-check | grep -F 'dry_run' >/dev/null; then
    fail "enforce helper left dry_run in authselect profile"
fi

as_root pwned-check-pam-disable
if authselect current -r | grep -F 'custom/pwned-check' >/dev/null; then
    fail "disable helper left custom pwned-check profile active"
fi
authselect current -r > "$before.after" 2>/dev/null || true
cmp -s "$before" "$before.after" || fail "authselect state did not return to pre-smoke state"
rm -f "$before" "$before.after"

pkg_tool remove "$PACKAGE_NAME"
if rpm -q "$PACKAGE_NAME" >/dev/null 2>&1; then
    fail "$PACKAGE_NAME is still installed after removal"
fi
for path in /usr/bin/pwned-check /usr/sbin/pwned-check-pam-enable-dry-run /usr/sbin/pwned-check-pam-enable-enforce /usr/sbin/pwned-check-pam-disable /lib64/security/pam_pwned_check.so /usr/share/pwned-check/authselect; do
    [ ! -e "$path" ] || fail "package-managed path still exists after removal: $path"
done

trap - EXIT INT TERM
cleanup
echo "Native PAM RPM repository smoke passed on $OS_ID"
EOF
