#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="${SOURCE_DATE_EPOCH:-}"
PWNED_CHECK_BIN=""
FAMILY="generic"

usage() {
    cat <<'EOF'
Usage: scripts/package-native-pam-generic-artifact.sh --version <version> [OPTIONS]

Build a generic native PAM filesystem-layout tarball for Linux distributions
that use explicit PAM file edits rather than pam-auth-update or authselect.

Options:
  --version <version>        Version label embedded in artifact names
  --output-dir <dir>         Output directory (default: dist/release)
  --build-time <timestamp>   Build timestamp metadata
  --pwned-check-bin <path>   Use an existing Linux pwned-check binary
  --family <name>            Distro family label for artifact metadata
  --help                     Show this help text
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
        --family)
            [ "$#" -ge 2 ] || fail "--family requires a value"
            FAMILY="$2"
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

[ -n "$VERSION" ] || fail "--version is required"

if [ "$(uname -s)" != "Linux" ]; then
    echo "native PAM generic artifact skipped: Linux host required" >&2
    exit 0
fi

require_command cargo
require_command gcc
require_command make
require_command pkg-config
require_command tar
if [ -z "$PWNED_CHECK_BIN" ]; then
    require_command go
else
    [ -x "$PWNED_CHECK_BIN" ] || fail "--pwned-check-bin is not executable: $PWNED_CHECK_BIN"
fi

case "$(uname -m)" in
    x86_64)
        ARTIFACT_ARCH="x86_64"
        GOARCH_VALUE="amd64"
        ;;
    aarch64|arm64)
        ARTIFACT_ARCH="aarch64"
        GOARCH_VALUE="arm64"
        ;;
    *)
        fail "unsupported generic native PAM architecture: $(uname -m)"
        ;;
esac

MODULE_DIR="$(pkg-config --variable=securedir pam 2>/dev/null || true)"
if [ "$FAMILY" = "alpine" ]; then
    MODULE_DIR="/usr/lib/security"
fi
if [ -z "$MODULE_DIR" ]; then
    case "$FAMILY" in
        arch) MODULE_DIR="/usr/lib/security" ;;
        alpine) MODULE_DIR="/usr/lib/security" ;;
        *) MODULE_DIR="/usr/lib/security" ;;
    esac
fi
EXTRA_MODULE_DIR=""
if [ "$FAMILY" = "alpine" ] && [ "$MODULE_DIR" != "/lib/security" ]; then
    EXTRA_MODULE_DIR="/lib/security"
fi
case "$FAMILY" in
    arch) HELPER_DIR="/usr/bin" ;;
    *) HELPER_DIR="/usr/sbin" ;;
esac

case "$MODULE_DIR" in
    /*) ;;
    *) fail "PAM module directory is not absolute: $MODULE_DIR" ;;
esac

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-generic.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

BASENAME="pwned-check-native-pam_${VERSION}_${FAMILY}_${ARTIFACT_ARCH}"
PACKAGE_DIR="$WORK_DIR/$BASENAME"
ROOTFS="$PACKAGE_DIR/rootfs"
DOC_DIR="$ROOTFS/usr/share/doc/pwned-check"
MANUAL_DIR="$ROOTFS/usr/share/pwned-check/manual-pam"
ROOTFS_MODULE_DIR="$ROOTFS$MODULE_DIR"

mkdir -p \
    "$DOC_DIR" \
    "$MANUAL_DIR" \
    "$ROOTFS/usr/bin" \
    "$ROOTFS$HELPER_DIR" \
    "$ROOTFS_MODULE_DIR" \
    "$PACKAGE_DIR/metadata"
if [ -n "$EXTRA_MODULE_DIR" ]; then
    mkdir -p "$ROOTFS$EXTRA_MODULE_DIR"
fi

(
    cd "$ROOT"
    make native-pam-build >/dev/null
    [ -f dist/pam_pwned_check.so ] || fail "dist/pam_pwned_check.so was not produced"
    install -m 0755 dist/pam_pwned_check.so "$ROOTFS_MODULE_DIR/pam_pwned_check.so"
    if [ -n "$EXTRA_MODULE_DIR" ]; then
        install -m 0755 dist/pam_pwned_check.so "$ROOTFS$EXTRA_MODULE_DIR/pam_pwned_check.so"
    fi

    if [ -n "$PWNED_CHECK_BIN" ]; then
        install -m 0755 "$PWNED_CHECK_BIN" "$ROOTFS/usr/bin/pwned-check"
    else
        CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" go build -trimpath \
            -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION" \
            -o "$ROOTFS/usr/bin/pwned-check" ./cmd/pwned-check
    fi

    cp README.md LICENSE "$DOC_DIR/"
    cp \
        docs/operations.md \
        docs/deployment-security-checklist.md \
        docs/troubleshooting.md \
        docs/logging-policy.md \
        docs/security-model.md \
        docs/provider-policy.md \
        docs/checker-contract.md \
        docs/production-release-gate.md \
        "$DOC_DIR/"
    if [ -n "$PWNED_CHECK_BIN" ]; then
        printf 'pwned-check binary supplied through --pwned-check-bin: %s\n' "$PWNED_CHECK_BIN" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
    elif command -v go >/dev/null 2>&1; then
        go version -m "$ROOTFS/usr/bin/pwned-check" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
        go list -m all > "$PACKAGE_DIR/metadata/go-modules.txt"
    fi
    if command -v ldd >/dev/null 2>&1; then
        ldd "$ROOTFS_MODULE_DIR/pam_pwned_check.so" > "$PACKAGE_DIR/metadata/pam_pwned_check-ldd.txt" || true
    fi
)

cat > "$MANUAL_DIR/enable-manual-pam.sh" <<'EOF'
#!/bin/sh
set -eu

SERVICE_PATH="${PWNED_CHECK_PAM_SERVICE_PATH:-/etc/pam.d/passwd}"
BACKUP_DIR="${PWNED_CHECK_BACKUP_DIR:-/var/lib/pwned-check/pam-backups}"
STATE_FILE="${PWNED_CHECK_STATE_FILE:-/var/lib/pwned-check/manual-pam-last-backup}"
INSERT_AFTER_PATTERN="${PWNED_CHECK_INSERT_AFTER_PATTERN:-}"
PROFILE_MODE="${PWNED_CHECK_PAM_MODE:-dry_run}"

case "$PROFILE_MODE" in
    dry_run)
        DEFAULT_MODULE_LINE='password    requisite                                    pam_pwned_check.so checker=/usr/bin/pwned-check timeout=3 fail_open dry_run'
        ;;
    enforce)
        DEFAULT_MODULE_LINE='password    requisite                                    pam_pwned_check.so checker=/usr/bin/pwned-check timeout=3 fail_open'
        ;;
    *)
        echo "PWNED_CHECK_PAM_MODE must be dry_run or enforce" >&2
        exit 2
        ;;
esac
MODULE_LINE="${PWNED_CHECK_MODULE_LINE:-$DEFAULT_MODULE_LINE}"

[ -f "$SERVICE_PATH" ] || {
    echo "PAM service file not found: $SERVICE_PATH" >&2
    exit 1
}

mkdir -p "$BACKUP_DIR" "$(dirname "$STATE_FILE")"
backup=""
if ! grep -F 'pam_pwned_check.so' "$SERVICE_PATH" >/dev/null || [ ! -f "$STATE_FILE" ]; then
    backup="$BACKUP_DIR/$(basename "$SERVICE_PATH").$(date -u '+%Y%m%dT%H%M%SZ')"
    cp "$SERVICE_PATH" "$backup"
    printf '%s\n' "$backup" > "$STATE_FILE"
fi

if grep -F 'pam_pwned_check.so' "$SERVICE_PATH" >/dev/null; then
    tmp="$(mktemp)"
    awk -v line="$MODULE_LINE" '
      /pam_pwned_check\.so/ && !updated {
        print line
        updated = 1
        next
      }
      { print }
    ' "$SERVICE_PATH" > "$tmp"
    cat "$tmp" > "$SERVICE_PATH"
    rm -f "$tmp"
    echo "Updated pwned-check in PAM service: $SERVICE_PATH"
    echo "Backup stored at: $(cat "$STATE_FILE")"
    exit 0
fi

tmp="$(mktemp)"
if [ -n "$INSERT_AFTER_PATTERN" ]; then
    awk -v line="$MODULE_LINE" -v pattern="$INSERT_AFTER_PATTERN" '
      { print }
      !inserted && index($0, pattern) > 0 {
        print line
        inserted = 1
      }
      END {
        if (!inserted) {
          print line
        }
      }
    ' "$SERVICE_PATH" > "$tmp"
else
    awk -v line="$MODULE_LINE" '
      !inserted && $1 == "password" {
        print line
        inserted = 1
      }
      { print }
      END {
        if (!inserted) {
          print line
        }
      }
    ' "$SERVICE_PATH" > "$tmp"
fi
cat "$tmp" > "$SERVICE_PATH"
rm -f "$tmp"

echo "Enabled pwned-check in PAM service: $SERVICE_PATH"
echo "Backup stored at: $(cat "$STATE_FILE")"
EOF
chmod 0755 "$MANUAL_DIR/enable-manual-pam.sh"

cat > "$ROOTFS$HELPER_DIR/pwned-check-pam-enable-dry-run" <<'EOF'
#!/bin/sh
set -eu

PWNED_CHECK_PAM_MODE=dry_run /usr/share/pwned-check/manual-pam/enable-manual-pam.sh
EOF
chmod 0755 "$ROOTFS$HELPER_DIR/pwned-check-pam-enable-dry-run"

cat > "$ROOTFS$HELPER_DIR/pwned-check-pam-enable-enforce" <<'EOF'
#!/bin/sh
set -eu

PWNED_CHECK_PAM_MODE=enforce /usr/share/pwned-check/manual-pam/enable-manual-pam.sh
EOF
chmod 0755 "$ROOTFS$HELPER_DIR/pwned-check-pam-enable-enforce"

cat > "$ROOTFS$HELPER_DIR/pwned-check-pam-disable" <<'EOF'
#!/bin/sh
set -eu

/usr/share/pwned-check/manual-pam/rollback-manual-pam.sh "$@"
EOF
chmod 0755 "$ROOTFS$HELPER_DIR/pwned-check-pam-disable"

cat > "$MANUAL_DIR/rollback-manual-pam.sh" <<'EOF'
#!/bin/sh
set -eu

STATE_FILE="${PWNED_CHECK_STATE_FILE:-/var/lib/pwned-check/manual-pam-last-backup}"
BACKUP_PATH="${1:-}"
if [ -z "$BACKUP_PATH" ] && [ -f "$STATE_FILE" ]; then
    BACKUP_PATH="$(cat "$STATE_FILE")"
fi

[ -n "$BACKUP_PATH" ] || {
    echo "usage: rollback-manual-pam.sh <backup-path>" >&2
    echo "or keep $STATE_FILE from enable-manual-pam.sh" >&2
    exit 2
}
[ -f "$BACKUP_PATH" ] || {
    echo "PAM backup not found: $BACKUP_PATH" >&2
    exit 1
}

service_name="$(basename "$BACKUP_PATH")"
service_name="${service_name%%.*}"
service_path="${PWNED_CHECK_PAM_SERVICE_PATH:-/etc/pam.d/$service_name}"
install -m 0644 "$BACKUP_PATH" "$service_path"
echo "Restored PAM service from backup: $service_path"
EOF
chmod 0755 "$MANUAL_DIR/rollback-manual-pam.sh"

cat > "$PACKAGE_DIR/metadata/build.json" <<EOF
{
  "version": "$VERSION",
  "family": "$FAMILY",
  "arch": "$ARTIFACT_ARCH",
  "goarch": "$GOARCH_VALUE",
  "module_path": "$MODULE_DIR/pam_pwned_check.so",
  "extra_module_path": "$(if [ -n "$EXTRA_MODULE_DIR" ]; then printf '%s/pam_pwned_check.so' "$EXTRA_MODULE_DIR"; fi)",
  "pwned_check_source": "$(if [ -n "$PWNED_CHECK_BIN" ]; then printf prebuilt; else printf built; fi)",
  "build_time": "$BUILD_TIME",
  "manual_enable": "/usr/share/pwned-check/manual-pam/enable-manual-pam.sh",
  "manual_rollback": "/usr/share/pwned-check/manual-pam/rollback-manual-pam.sh",
  "enable_dry_run_helper": "$HELPER_DIR/pwned-check-pam-enable-dry-run",
  "enable_enforce_helper": "$HELPER_DIR/pwned-check-pam-enable-enforce",
  "disable_helper": "$HELPER_DIR/pwned-check-pam-disable",
  "profile_mode": "dry_run"
}
EOF

cat > "$PACKAGE_DIR/README.native-pam-generic.md" <<EOF
# pwned-check Native PAM Generic Artifact

This filesystem-layout artifact installs the native Linux PAM module and
checker binary for distributions that use explicit PAM service file edits.

Contents:

- \`/usr/bin/pwned-check\`
- \`$MODULE_DIR/pam_pwned_check.so\`
- \`/usr/share/pwned-check/manual-pam/enable-manual-pam.sh\`
- \`/usr/share/pwned-check/manual-pam/rollback-manual-pam.sh\`
- \`$HELPER_DIR/pwned-check-pam-enable-dry-run\`
- \`$HELPER_DIR/pwned-check-pam-enable-enforce\`
- \`$HELPER_DIR/pwned-check-pam-disable\`
- \`/usr/share/doc/pwned-check/\`

The enable helper edits \`/etc/pam.d/passwd\` by default, creates a timestamped
backup under \`/var/lib/pwned-check/pam-backups\`, and records the last backup
path for rollback. The inserted module line ships with \`dry_run\` enabled.

Install:

\`\`\`sh
sudo ./install.sh
\`\`\`

Enable:

\`\`\`sh
sudo pwned-check-pam-enable-dry-run
\`\`\`

Switch to enforcement after validating dry-run behavior and rollback:

\`\`\`sh
sudo pwned-check-pam-enable-enforce
\`\`\`

Rollback:

\`\`\`sh
sudo pwned-check-pam-disable
\`\`\`
EOF

cat > "$PACKAGE_DIR/install.sh" <<'EOF'
#!/bin/sh
set -eu

DESTDIR="${DESTDIR:-}"

copy_tree() {
    src="$1"
    dest="$2"
    find "$src" -type d | while IFS= read -r dir; do
        rel="${dir#$src}"
        [ -n "$rel" ] || continue
        install -d "$dest$rel"
    done
    find "$src" -type f | while IFS= read -r file; do
        rel="${file#$src}"
        mode="0644"
        case "$rel" in
            /usr/bin/pwned-check|*/pwned-check-pam-*|*/security/pam_pwned_check.so|/usr/share/pwned-check/manual-pam/*.sh)
                mode="0755"
                ;;
        esac
        install -m "$mode" "$file" "$dest$rel"
    done
}

copy_tree ./rootfs "$DESTDIR"

if [ -z "$DESTDIR" ]; then
    /usr/bin/pwned-check --version
    echo "Installed manual PAM helpers under /usr/share/pwned-check/manual-pam"
    echo "Run 'sudo pwned-check-pam-enable-dry-run' to enable dry-run mode."
    echo "Run 'sudo pwned-check-pam-enable-enforce' after validating rollback."
fi
EOF
chmod 0755 "$PACKAGE_DIR/install.sh"

mkdir -p "$OUTPUT_DIR"
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
