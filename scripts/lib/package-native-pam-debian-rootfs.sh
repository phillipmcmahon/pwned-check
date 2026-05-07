#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
Usage: scripts/lib/package-native-pam-debian-rootfs.sh --version <version> [OPTIONS]

Build the Debian/Ubuntu native PAM staging rootfs for the current Linux
architecture. The tarball is consumed by the .deb package builder.

Options:
  --version <version>      Release version, for example X.Y.Z or dev-abcdef12
  --output-dir <path>      Output directory (default: dist/release)
  --build-time <time>      RFC3339 build time (default: current UTC time)
  --pwned-check-bin <path> Use a prebuilt Linux pwned-check binary
  --help                   Show this help text
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PWNED_CHECK_BIN=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            [ "$#" -ge 2 ] || fail "--version requires a value"
            VERSION="$2"
            shift 2
            ;;
        --output-dir)
            [ "$#" -ge 2 ] || fail "--output-dir requires a value"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --build-time)
            [ "$#" -ge 2 ] || fail "--build-time requires a value"
            BUILD_TIME="$2"
            shift 2
            ;;
        --pwned-check-bin)
            [ "$#" -ge 2 ] || fail "--pwned-check-bin requires a value"
            PWNED_CHECK_BIN="$2"
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

[ -n "$VERSION" ] || fail "--version is required"
[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM Debian rootfs skipped: Linux host required"
    exit 0
}

require_command cargo
require_command gcc
require_command tar
if [ -z "$PWNED_CHECK_BIN" ]; then
    require_command go
else
    [ -f "$PWNED_CHECK_BIN" ] || fail "prebuilt pwned-check binary not found: $PWNED_CHECK_BIN"
fi

if command -v dpkg >/dev/null 2>&1; then
    DEB_ARCH="$(dpkg --print-architecture)"
else
    case "$(uname -m)" in
        x86_64) DEB_ARCH="amd64" ;;
        aarch64|arm64) DEB_ARCH="arm64" ;;
        *) fail "unsupported Debian architecture: $(uname -m)" ;;
    esac
fi

MULTIARCH="$(gcc -print-multiarch)"
[ -n "$MULTIARCH" ] || fail "could not determine GCC multiarch tuple"

case "$DEB_ARCH" in
    amd64) GOARCH_VALUE="amd64" ;;
    arm64) GOARCH_VALUE="arm64" ;;
    *) fail "unsupported Debian architecture: $DEB_ARCH" ;;
esac

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-debian.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

BASENAME="pwned-check-native-pam_${VERSION}_debian_${DEB_ARCH}"
PACKAGE_DIR="$WORK_DIR/$BASENAME"
ROOTFS="$PACKAGE_DIR/rootfs"
DOC_DIR="$ROOTFS/usr/share/doc/pwned-check"
MODULE_DIR="$ROOTFS/lib/$MULTIARCH/security"
DEBIAN_PAM_DIR="$ROOTFS/usr/share/pwned-check/debian-pam"

mkdir -p \
    "$DOC_DIR" \
    "$MODULE_DIR" \
    "$ROOTFS/usr/bin" \
    "$ROOTFS/usr/sbin" \
    "$ROOTFS/usr/share/pam-configs" \
    "$DEBIAN_PAM_DIR" \
    "$PACKAGE_DIR/metadata"

(
    cd "$ROOT"
    make native-pam-build >/dev/null
    [ -f dist/pam_pwned_check.so ] || fail "dist/pam_pwned_check.so was not produced"
    install -m 0644 dist/pam_pwned_check.so "$MODULE_DIR/pam_pwned_check.so"

    if [ -n "$PWNED_CHECK_BIN" ]; then
        install -m 0755 "$PWNED_CHECK_BIN" "$ROOTFS/usr/bin/pwned-check"
    else
        CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" go build -trimpath \
            -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION" \
            -o "$ROOTFS/usr/bin/pwned-check" ./cmd/pwned-check
    fi

    cp README.md LICENSE "$DOC_DIR/"
    cp \
        docs/linux-install.md \
        docs/logging-policy.md \
        docs/security-model.md \
        docs/provider-policy.md \
        docs/checker-contract.md \
        "$DOC_DIR/"
    if [ -n "$PWNED_CHECK_BIN" ]; then
        printf 'pwned-check binary supplied through --pwned-check-bin: %s\n' "$PWNED_CHECK_BIN" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
    elif command -v go >/dev/null 2>&1; then
        go version -m "$ROOTFS/usr/bin/pwned-check" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
        go list -m all > "$PACKAGE_DIR/metadata/go-modules.txt"
    else
        printf 'go command unavailable; pwned-check binary supplied through --pwned-check-bin\n' > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
    fi
    if command -v ldd >/dev/null 2>&1; then
        ldd "$MODULE_DIR/pam_pwned_check.so" > "$PACKAGE_DIR/metadata/pam_pwned_check-ldd.txt"
    fi
)

cat > "$ROOTFS/usr/share/pam-configs/pwned-check" <<'EOF'
Name: pwned-check native password breach check
Default: no
Priority: 512
Password-Type: Primary
Password:
	requisite	pam_pwned_check.so checker=/usr/bin/pwned-check timeout=3 fail_open dry_run
EOF

cat > "$DEBIAN_PAM_DIR/set-profile-mode.sh" <<'EOF'
#!/bin/sh
set -eu

PROFILE_PATH="${PWNED_CHECK_PAM_PROFILE_PATH:-/usr/share/pam-configs/pwned-check}"
MODE="${1:-}"
FAIL_POLICY="${2:-fail_open}"

case "$MODE" in
    dry-run|enforce) ;;
    *)
        echo "usage: set-profile-mode.sh dry-run|enforce [fail_open|fail_closed]" >&2
        exit 2
        ;;
esac
case "$FAIL_POLICY" in
    fail_open|fail_closed) ;;
    *)
        echo "fail policy must be fail_open or fail_closed" >&2
        exit 2
        ;;
esac

[ "$(id -u)" -eq 0 ] || {
    echo "pwned-check PAM mode changes must run as root" >&2
    exit 1
}
[ -f "$PROFILE_PATH" ] || {
    echo "pwned-check PAM profile not found: $PROFILE_PATH" >&2
    exit 1
}

tmp="$(mktemp "${TMPDIR:-/tmp}/pwned-check-pam-profile.XXXXXX")"
cleanup() {
    rm -f "$tmp"
}
trap cleanup EXIT INT TERM

awk -v mode="$MODE" -v fail_policy="$FAIL_POLICY" '
    /pam_pwned_check\.so/ {
        gsub(/[[:space:]]+dry_run/, "")
        gsub(/[[:space:]]+fail_open/, "")
        gsub(/[[:space:]]+fail_closed/, "")
        sub(/[[:space:]]*$/, " " fail_policy)
        if (mode == "dry-run") {
            sub(/[[:space:]]*$/, " dry_run")
        }
    }
    { print }
' "$PROFILE_PATH" > "$tmp"

install -m 0644 "$tmp" "$PROFILE_PATH"
EOF
chmod 0755 "$DEBIAN_PAM_DIR/set-profile-mode.sh"

cat > "$ROOTFS/usr/sbin/pwned-check-pam-enable-dry-run" <<'EOF'
#!/bin/sh
set -eu

[ "$#" -le 1 ] || {
    echo "usage: pwned-check-pam-enable-dry-run [--fail-open|--fail-closed]" >&2
    exit 2
}
case "${1:-}" in
    ""|--fail-open) fail_policy="fail_open" ;;
    --fail-closed) fail_policy="fail_closed" ;;
    *) echo "usage: pwned-check-pam-enable-dry-run [--fail-open|--fail-closed]" >&2; exit 2 ;;
esac
/usr/share/pwned-check/debian-pam/set-profile-mode.sh dry-run "$fail_policy"
if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --enable pwned-check --package; then
    echo "pam-auth-update failed; PAM configuration unchanged" >&2
    exit 1
fi
echo "pwned-check native PAM enabled in dry-run mode"
EOF
chmod 0755 "$ROOTFS/usr/sbin/pwned-check-pam-enable-dry-run"

cat > "$ROOTFS/usr/sbin/pwned-check-pam-enable-enforce" <<'EOF'
#!/bin/sh
set -eu

[ "$#" -le 1 ] || {
    echo "usage: pwned-check-pam-enable-enforce [--fail-open|--fail-closed]" >&2
    exit 2
}
case "${1:-}" in
    ""|--fail-open) fail_policy="fail_open" ;;
    --fail-closed) fail_policy="fail_closed" ;;
    *) echo "usage: pwned-check-pam-enable-enforce [--fail-open|--fail-closed]" >&2; exit 2 ;;
esac
/usr/share/pwned-check/debian-pam/set-profile-mode.sh enforce "$fail_policy"
if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --enable pwned-check --package; then
    echo "pam-auth-update failed; PAM configuration unchanged" >&2
    exit 1
fi
echo "pwned-check native PAM enabled in enforcement mode"
EOF
chmod 0755 "$ROOTFS/usr/sbin/pwned-check-pam-enable-enforce"

cat > "$ROOTFS/usr/sbin/pwned-check-pam-disable" <<'EOF'
#!/bin/sh
set -eu

if ! DEBIAN_FRONTEND=noninteractive pam-auth-update --disable pwned-check --package; then
    echo "pam-auth-update failed; PAM configuration may still reference pwned-check" >&2
    exit 1
fi
echo "pwned-check native PAM disabled"
EOF
chmod 0755 "$ROOTFS/usr/sbin/pwned-check-pam-disable"

cat > "$PACKAGE_DIR/metadata/build.json" <<EOF
{
  "version": "$VERSION",
  "debian_arch": "$DEB_ARCH",
  "multiarch": "$MULTIARCH",
  "goarch": "$GOARCH_VALUE",
  "pwned_check_source": "$(if [ -n "$PWNED_CHECK_BIN" ]; then printf prebuilt; else printf built; fi)",
  "build_time": "$BUILD_TIME",
  "pam_auth_update_profile": "/usr/share/pam-configs/pwned-check",
  "enable_dry_run_helper": "/usr/sbin/pwned-check-pam-enable-dry-run",
  "enable_enforce_helper": "/usr/sbin/pwned-check-pam-enable-enforce",
  "disable_helper": "/usr/sbin/pwned-check-pam-disable",
  "profile_default": "no",
  "profile_mode": "dry_run"
}
EOF

(
    cd "$WORK_DIR"
    COPYFILE_DISABLE=1 tar -czf "$OUTPUT_DIR/$BASENAME.tar.gz" "$BASENAME"
)

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$OUTPUT_DIR"
        sha256sum "$BASENAME.tar.gz" > "$BASENAME.tar.gz.sha256"
    )
else
    (
        cd "$OUTPUT_DIR"
        shasum -a 256 "$BASENAME.tar.gz" | awk '{print $1 "  " $2}' > "$BASENAME.tar.gz.sha256"
    )
fi

printf '%s\n' "$BASENAME"
