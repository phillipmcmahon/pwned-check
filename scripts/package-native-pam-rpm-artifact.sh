#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="${SOURCE_DATE_EPOCH:-}"
PWNED_CHECK_BIN=""

usage() {
    cat <<'EOF'
Usage: scripts/package-native-pam-rpm-artifact.sh --version <version> [OPTIONS]

Build an RPM-family native PAM filesystem-layout tarball for the current
Linux architecture. The artifact includes pwned-check, pam_pwned_check.so,
authselect enable/rollback helpers, docs, and build metadata.

Options:
  --version <version>        Version label embedded in artifact names
  --output-dir <dir>         Output directory (default: dist/release)
  --build-time <timestamp>   Build timestamp metadata
  --pwned-check-bin <path>   Use an existing Linux pwned-check binary
  --help                     Show this help text
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
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
    echo "native PAM RPM-family artifact skipped: Linux host required" >&2
    exit 0
fi

case "$(uname -m)" in
    x86_64)
        RPM_ARCH="x86_64"
        GOARCH_VALUE="amd64"
        ;;
    aarch64|arm64)
        RPM_ARCH="aarch64"
        GOARCH_VALUE="arm64"
        ;;
    *)
        fail "unsupported RPM-family architecture: $(uname -m)"
        ;;
esac

[ -z "$PWNED_CHECK_BIN" ] || [ -x "$PWNED_CHECK_BIN" ] || fail "--pwned-check-bin is not executable: $PWNED_CHECK_BIN"

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-rpm.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

BASENAME="pwned-check-native-pam_${VERSION}_rpm_${RPM_ARCH}"
PACKAGE_DIR="$WORK_DIR/$BASENAME"
ROOTFS="$PACKAGE_DIR/rootfs"
MODULE_DIR="$ROOTFS/lib64/security"
DOC_DIR="$ROOTFS/usr/share/doc/pwned-check"
AUTHSELECT_DIR="$ROOTFS/usr/share/pwned-check/authselect"

mkdir -p \
    "$MODULE_DIR" \
    "$ROOTFS/usr/bin" \
    "$ROOTFS/usr/sbin" \
    "$DOC_DIR" \
    "$AUTHSELECT_DIR" \
    "$PACKAGE_DIR/metadata"

(
    cd "$ROOT"
    make native-pam-build >/dev/null
    [ -f dist/pam_pwned_check.so ] || fail "dist/pam_pwned_check.so was not produced"
    install -m 0755 dist/pam_pwned_check.so "$MODULE_DIR/pam_pwned_check.so"

    if [ -n "$PWNED_CHECK_BIN" ]; then
        install -m 0755 "$PWNED_CHECK_BIN" "$ROOTFS/usr/bin/pwned-check"
    else
        CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH_VALUE" go build -trimpath \
            -ldflags "-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION" \
            -o "$ROOTFS/usr/bin/pwned-check" ./cmd/pwned-check
    fi

    cp README.md LICENSE "$DOC_DIR/"
    cp docs/native-pam-module.md docs/logging-policy.md docs/testing.md "$DOC_DIR/"
    if [ -n "$PWNED_CHECK_BIN" ]; then
        printf 'pwned-check binary supplied through --pwned-check-bin: %s\n' "$PWNED_CHECK_BIN" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
    elif command -v go >/dev/null 2>&1; then
        go version -m "$ROOTFS/usr/bin/pwned-check" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
        go list -m all > "$PACKAGE_DIR/metadata/go-modules.txt"
    fi
    if command -v ldd >/dev/null 2>&1; then
        ldd "$MODULE_DIR/pam_pwned_check.so" > "$PACKAGE_DIR/metadata/pam_pwned_check-ldd.txt"
    fi
)

cat > "$AUTHSELECT_DIR/enable-authselect.sh" <<'EOF'
#!/bin/sh
set -eu

PROFILE_NAME="${PWNED_CHECK_AUTHSELECT_PROFILE:-pwned-check}"
BACKUP_NAME="${PWNED_CHECK_AUTHSELECT_BACKUP:-pwned-check-$(date -u '+%Y%m%dT%H%M%SZ')}"
STATE_DIR="${PWNED_CHECK_STATE_DIR:-/var/lib/pwned-check}"
PROFILE_MODE="${PWNED_CHECK_PAM_MODE:-dry_run}"

case "$PROFILE_MODE" in
    dry_run)
        PAM_LINE='password    requisite                                    pam_pwned_check.so checker=/usr/bin/pwned-check timeout=3 fail_open dry_run'
        ;;
    enforce)
        PAM_LINE='password    requisite                                    pam_pwned_check.so checker=/usr/bin/pwned-check timeout=3 fail_open'
        ;;
    *)
        echo "PWNED_CHECK_PAM_MODE must be dry_run or enforce" >&2
        exit 2
        ;;
esac

command -v authselect >/dev/null 2>&1 || {
    echo "authselect is required to enable the RPM-family native PAM module" >&2
    exit 1
}

current_raw="$(authselect current -r 2>/dev/null || true)"
current_profile=""
case "$current_raw" in
    ""|No\ *)
        base_profile="sssd"
        features=""
        ;;
    *)
        current_profile="${current_raw%% *}"
        base_profile="$current_profile"
        features="${current_raw#"$base_profile"}"
        ;;
esac

case "$base_profile" in
    custom/*)
        base_for_create="$base_profile"
        ;;
    *)
        base_for_create="$base_profile"
        ;;
esac

if ! authselect list 2>/dev/null | grep -F "custom/$PROFILE_NAME" >/dev/null; then
    if ! authselect create-profile "$PROFILE_NAME" --base-on "$base_for_create"; then
        echo "authselect create-profile failed; active PAM configuration unchanged" >&2
        exit 1
    fi
fi

for stack in system-auth password-auth; do
    path="/etc/authselect/custom/$PROFILE_NAME/$stack"
    [ -f "$path" ] || {
        echo "authselect custom profile is missing $stack: $path" >&2
        exit 1
    }
    if grep -F 'pam_pwned_check.so' "$path" >/dev/null; then
        tmp="$(mktemp)"
        awk -v line="$PAM_LINE" '
          /pam_pwned_check\.so/ && !replaced {
            print line
            replaced = 1
            next
          }
          /pam_pwned_check\.so/ {
            next
          }
          { print }
        ' "$path" > "$tmp"
        cat "$tmp" > "$path"
        rm -f "$tmp"
    else
        tmp="$(mktemp)"
        awk -v line="$PAM_LINE" '
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
        ' "$path" > "$tmp"
        cat "$tmp" > "$path"
        rm -f "$tmp"
    fi
done

mkdir -p "$STATE_DIR"
if [ "$current_profile" = "custom/$PROFILE_NAME" ]; then
    if ! authselect apply-changes; then
        echo "authselect apply-changes failed; custom profile changes were not applied cleanly" >&2
        exit 1
    fi
else
    printf '%s\n' "$BACKUP_NAME" > "$STATE_DIR/authselect-last-backup"
    # shellcheck disable=SC2086
    if ! authselect select "custom/$PROFILE_NAME" $features --backup="$BACKUP_NAME" --force; then
        echo "authselect select failed; active PAM configuration may be unchanged" >&2
        exit 1
    fi
fi
if ! authselect check; then
    echo "authselect check failed after enabling pwned-check" >&2
    exit 1
fi
echo "Enabled pwned-check authselect profile: custom/$PROFILE_NAME ($PROFILE_MODE)"
if [ -f "$STATE_DIR/authselect-last-backup" ]; then
    echo "Authselect backup: $(cat "$STATE_DIR/authselect-last-backup")"
fi
EOF
chmod 0755 "$AUTHSELECT_DIR/enable-authselect.sh"

cat > "$ROOTFS/usr/sbin/pwned-check-pam-enable-dry-run" <<'EOF'
#!/bin/sh
set -eu

PWNED_CHECK_PAM_MODE=dry_run /usr/share/pwned-check/authselect/enable-authselect.sh
EOF
chmod 0755 "$ROOTFS/usr/sbin/pwned-check-pam-enable-dry-run"

cat > "$ROOTFS/usr/sbin/pwned-check-pam-enable-enforce" <<'EOF'
#!/bin/sh
set -eu

PWNED_CHECK_PAM_MODE=enforce /usr/share/pwned-check/authselect/enable-authselect.sh
EOF
chmod 0755 "$ROOTFS/usr/sbin/pwned-check-pam-enable-enforce"

cat > "$ROOTFS/usr/sbin/pwned-check-pam-disable" <<'EOF'
#!/bin/sh
set -eu

/usr/share/pwned-check/authselect/rollback-authselect.sh "$@"
EOF
chmod 0755 "$ROOTFS/usr/sbin/pwned-check-pam-disable"

cat > "$AUTHSELECT_DIR/rollback-authselect.sh" <<'EOF'
#!/bin/sh
set -eu

STATE_DIR="${PWNED_CHECK_STATE_DIR:-/var/lib/pwned-check}"
BACKUP_NAME="${1:-}"
if [ -z "$BACKUP_NAME" ] && [ -f "$STATE_DIR/authselect-last-backup" ]; then
    BACKUP_NAME="$(cat "$STATE_DIR/authselect-last-backup")"
fi

[ -n "$BACKUP_NAME" ] || {
    echo "usage: rollback-authselect.sh <authselect-backup-name>" >&2
    echo "or keep $STATE_DIR/authselect-last-backup from enable-authselect.sh" >&2
    exit 2
}

if ! authselect backup-restore "$BACKUP_NAME"; then
    echo "authselect backup-restore failed; PAM configuration may still reference pwned-check" >&2
    exit 1
fi
if ! authselect check; then
    echo "Warning: authselect backup was restored, but authselect check reports the restored state is not currently valid." >&2
fi
echo "Restored authselect backup: $BACKUP_NAME"
EOF
chmod 0755 "$AUTHSELECT_DIR/rollback-authselect.sh"

cat > "$PACKAGE_DIR/metadata/build.json" <<EOF
{
  "version": "$VERSION",
  "rpm_arch": "$RPM_ARCH",
  "module_path": "/lib64/security/pam_pwned_check.so",
  "pwned_check_source": "$(if [ -n "$PWNED_CHECK_BIN" ]; then printf prebuilt; else printf built; fi)",
  "build_time": "$BUILD_TIME",
  "authselect_enable": "/usr/share/pwned-check/authselect/enable-authselect.sh",
  "authselect_rollback": "/usr/share/pwned-check/authselect/rollback-authselect.sh",
  "enable_dry_run_helper": "/usr/sbin/pwned-check-pam-enable-dry-run",
  "enable_enforce_helper": "/usr/sbin/pwned-check-pam-enable-enforce",
  "disable_helper": "/usr/sbin/pwned-check-pam-disable",
  "profile_mode": "dry_run"
}
EOF

cat > "$PACKAGE_DIR/README.native-pam-rpm.md" <<EOF
# pwned-check Native PAM RPM-Family Artifact

This filesystem-layout artifact installs the native Linux PAM module and checker
binary for Fedora/RHEL/Rocky-style systems.

Contents:

- \`/usr/bin/pwned-check\`
- \`/lib64/security/pam_pwned_check.so\`
- \`/usr/share/pwned-check/authselect/enable-authselect.sh\`
- \`/usr/share/pwned-check/authselect/rollback-authselect.sh\`
- \`/usr/sbin/pwned-check-pam-enable-dry-run\`
- \`/usr/sbin/pwned-check-pam-enable-enforce\`
- \`/usr/sbin/pwned-check-pam-disable\`
- \`/usr/share/doc/pwned-check/\`

The authselect helper creates a custom profile from the currently selected
profile, inserts \`pam_pwned_check.so\` at the start of the password stack, and
selects that custom profile with an authselect backup. The inserted module line
ships with \`dry_run\` enabled. Enabling the profile should be a staged rollout
action, not a package installation side effect.

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
            /usr/bin/pwned-check|/usr/sbin/pwned-check-pam-*|/lib64/security/pam_pwned_check.so|/usr/share/pwned-check/authselect/*.sh)
                mode="0755"
                ;;
        esac
        install -m "$mode" "$file" "$dest$rel"
    done
}

copy_tree ./rootfs "$DESTDIR"

if [ -z "$DESTDIR" ]; then
    /usr/bin/pwned-check --version
    if command -v authselect >/dev/null 2>&1; then
        echo "Installed authselect helpers under /usr/share/pwned-check/authselect"
        echo "Run 'sudo pwned-check-pam-enable-dry-run' to enable dry-run mode."
        echo "Run 'sudo pwned-check-pam-enable-enforce' after validating rollback."
    fi
fi
EOF
chmod 0755 "$PACKAGE_DIR/install.sh"

mkdir -p "$OUTPUT_DIR"
TAR_CREATE_FLAGS="--format=ustar"
if tar --help 2>/dev/null | grep -q -- '--no-xattrs'; then
    TAR_CREATE_FLAGS="$TAR_CREATE_FLAGS --no-xattrs"
fi
if tar --help 2>/dev/null | grep -q -- '--no-acls'; then
    TAR_CREATE_FLAGS="$TAR_CREATE_FLAGS --no-acls"
fi
if tar --help 2>/dev/null | grep -q -- '--no-selinux'; then
    TAR_CREATE_FLAGS="$TAR_CREATE_FLAGS --no-selinux"
fi
(
    cd "$WORK_DIR"
    # shellcheck disable=SC2086
    COPYFILE_DISABLE=1 tar $TAR_CREATE_FLAGS -czf "$OUTPUT_DIR/$BASENAME.tar.gz" "$BASENAME"
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
