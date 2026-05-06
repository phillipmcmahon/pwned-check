#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="${SOURCE_DATE_EPOCH:-}"
PWNED_CHECK_BIN=""

usage() {
    cat <<'EOF'
Usage: scripts/package-native-pam-debian-package.sh --version <version> [OPTIONS]

Build a native .deb package for Debian/Ubuntu systems. The builder assembles a
staging rootfs and installs pam_pwned_check.so, pwned-check, a pam-auth-update
profile, documentation, mode helpers, and package metadata.

Options:
  --version <version>      Version label embedded in package metadata
  --output-dir <path>      Output directory (default: dist/release)
  --build-time <time>      RFC3339 build time
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
    echo "native PAM Debian package skipped: Linux host required" >&2
    exit 0
fi

require_command dpkg
require_command dpkg-deb
require_command tar

[ -z "$PWNED_CHECK_BIN" ] || [ -x "$PWNED_CHECK_BIN" ] || fail "--pwned-check-bin is not executable: $PWNED_CHECK_BIN"

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
    amd64|arm64) ;;
    *) fail "unsupported Debian architecture: $DEB_ARCH" ;;
esac

DEB_VERSION="$(printf '%s' "$VERSION" | sed 's/^v//; s/[^A-Za-z0-9.+:~]/+/g')"
[ -n "$DEB_VERSION" ] || DEB_VERSION=0
case "$DEB_VERSION" in
    [0-9]*) ;;
    *) DEB_VERSION="0+$DEB_VERSION" ;;
esac

PACKAGE_NAME="pwned-check-native-pam"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-debian-package.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

ARTIFACT_OUT="$WORK_DIR/artifacts"
mkdir -p "$ARTIFACT_OUT" "$OUTPUT_DIR"

if [ -n "$PWNED_CHECK_BIN" ]; then
    artifact_name="$(cd "$ROOT" && ./scripts/package-native-pam-debian-artifact.sh --version "$VERSION" --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME" --pwned-check-bin "$PWNED_CHECK_BIN")"
else
    artifact_name="$(cd "$ROOT" && ./scripts/package-native-pam-debian-artifact.sh --version "$VERSION" --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME")"
fi
artifact="$ARTIFACT_OUT/$artifact_name.tar.gz"
[ -f "$artifact" ] || fail "artifact was not produced: $artifact"

PACKAGE_DIR="$WORK_DIR/package"
mkdir -p "$PACKAGE_DIR"
tar -xzf "$artifact" -C "$WORK_DIR"
cp -a "$WORK_DIR/$artifact_name/rootfs/." "$PACKAGE_DIR/"
mkdir -p "$PACKAGE_DIR/DEBIAN"

installed_size="$(du -sk "$PACKAGE_DIR" | awk '{print $1}')"

cat > "$PACKAGE_DIR/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $DEB_VERSION
Section: admin
Priority: optional
Architecture: $DEB_ARCH
Maintainer: pwned-check maintainers <noreply@example.invalid>
Installed-Size: $installed_size
Depends: libpam0g, libpam-runtime
Description: Native Linux PAM module for pwned-check
 pwned-check native Linux PAM module package for Debian/Ubuntu systems.
 The package installs pam_pwned_check.so, the pwned-check CLI, a
 pam-auth-update profile, mode helpers, and operator documentation.
 Package installation does not enable the PAM module; enablement is an
 explicit operator action through the packaged mode helpers.
EOF

cat > "$PACKAGE_DIR/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

if [ "$1" = "configure" ] && command -v pam-auth-update >/dev/null 2>&1; then
    echo "pwned-check native PAM installed. Run 'pwned-check-pam-enable-dry-run' to enable dry-run mode."
fi
EOF
chmod 0755 "$PACKAGE_DIR/DEBIAN/postinst"

cat > "$PACKAGE_DIR/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e

case "$1" in
    remove|deconfigure)
        if command -v pam-auth-update >/dev/null 2>&1 && [ -f /usr/share/pam-configs/pwned-check ]; then
            DEBIAN_FRONTEND=noninteractive pam-auth-update --disable pwned-check --package || true
        fi
        ;;
esac
EOF
chmod 0755 "$PACKAGE_DIR/DEBIAN/prerm"

find "$PACKAGE_DIR" -type f ! -path "$PACKAGE_DIR/DEBIAN/*" -exec md5sum {} \; \
    | sed "s#  $PACKAGE_DIR/#  #" > "$PACKAGE_DIR/DEBIAN/md5sums"

deb_name="${PACKAGE_NAME}_${DEB_VERSION}_${DEB_ARCH}.deb"
dpkg-deb --root-owner-group --build "$PACKAGE_DIR" "$OUTPUT_DIR/$deb_name" >/dev/null

metadata="$OUTPUT_DIR/$deb_name.build-metadata.json"
cat > "$metadata" <<EOF
{
  "version": "$VERSION",
  "debian_version": "$DEB_VERSION",
  "debian_arch": "$DEB_ARCH",
  "package": "$deb_name",
  "source_artifact": "$artifact_name.tar.gz",
  "build_time": "$BUILD_TIME"
}
EOF

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$OUTPUT_DIR"
        sha256sum "$deb_name" > "$deb_name.sha256"
        sha256sum "$(basename "$metadata")" > "$(basename "$metadata").sha256"
    )
else
    (
        cd "$OUTPUT_DIR"
        shasum -a 256 "$deb_name" | awk '{print $1 "  " $2}' > "$deb_name.sha256"
        shasum -a 256 "$(basename "$metadata")" | awk '{print $1 "  " $2}' > "$(basename "$metadata").sha256"
    )
fi

printf '%s\n' "$deb_name"
