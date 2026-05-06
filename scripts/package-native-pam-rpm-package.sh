#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="${SOURCE_DATE_EPOCH:-}"
PWNED_CHECK_BIN=""

usage() {
    cat <<'EOF'
Usage: scripts/package-native-pam-rpm-package.sh --version <version> [OPTIONS]

Build a native RPM package for Fedora/RHEL/Rocky systems. The RPM is built from
the RPM-family filesystem-layout artifact and installs pam_pwned_check.so,
pwned-check, authselect helpers, documentation, and package metadata.

Options:
  --version <version>        Version label embedded in package metadata
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
    echo "native PAM RPM package skipped: Linux host required" >&2
    exit 0
fi

case "$(uname -m)" in
    x86_64)
        RPM_ARCH="x86_64"
        ;;
    aarch64|arm64)
        RPM_ARCH="aarch64"
        ;;
    *)
        fail "unsupported RPM architecture: $(uname -m)"
        ;;
esac

require_command rpmbuild
require_command rpm
require_command tar

[ -z "$PWNED_CHECK_BIN" ] || [ -x "$PWNED_CHECK_BIN" ] || fail "--pwned-check-bin is not executable: $PWNED_CHECK_BIN"

if [ -z "$BUILD_TIME" ]; then
    BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi

RPM_VERSION="$(printf '%s' "$VERSION" | sed 's/^v//; s/[^A-Za-z0-9._+~]/_/g')"
[ -n "$RPM_VERSION" ] || RPM_VERSION=0
PACKAGE_NAME="pwned-check-native-pam"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-native-pam-rpm-package.XXXXXX")"
cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

ARTIFACT_OUT="$WORK_DIR/artifacts"
mkdir -p "$ARTIFACT_OUT" "$OUTPUT_DIR"

if [ -n "$PWNED_CHECK_BIN" ]; then
    artifact_name="$(cd "$ROOT" && ./scripts/package-native-pam-rpm-artifact.sh --version "$VERSION" --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME" --pwned-check-bin "$PWNED_CHECK_BIN")"
else
    artifact_name="$(cd "$ROOT" && ./scripts/package-native-pam-rpm-artifact.sh --version "$VERSION" --output-dir "$ARTIFACT_OUT" --build-time "$BUILD_TIME")"
fi
artifact="$ARTIFACT_OUT/$artifact_name.tar.gz"
[ -f "$artifact" ] || fail "artifact was not produced: $artifact"

TOPDIR="$WORK_DIR/rpmbuild"
mkdir -p "$TOPDIR/BUILD" "$TOPDIR/BUILDROOT" "$TOPDIR/RPMS" "$TOPDIR/SOURCES" "$TOPDIR/SPECS" "$TOPDIR/SRPMS"
cp "$artifact" "$TOPDIR/SOURCES/"

cat > "$TOPDIR/SPECS/$PACKAGE_NAME.spec" <<EOF
%global debug_package %{nil}
Name:           $PACKAGE_NAME
Version:        $RPM_VERSION
Release:        1%{?dist}
Summary:        Native Linux PAM module for pwned-check
License:        MIT
URL:            https://github.com/phillipmcmahon/pwned-check
Source0:        $artifact_name.tar.gz
ExclusiveArch:  x86_64 aarch64
Requires:       pam
Requires:       authselect

%description
pwned-check native Linux PAM module package for Fedora/RHEL/Rocky-style
systems. The package installs pam_pwned_check.so, the pwned-check CLI,
authselect enable/rollback helpers, and operator documentation. Package
installation does not enable the PAM module; enablement is an explicit
operator action through the authselect helper.

%prep
%setup -q -n $artifact_name

%build

%install
mkdir -p %{buildroot}
cp -a rootfs/. %{buildroot}/

%check
test -x %{buildroot}/usr/bin/pwned-check
test -x %{buildroot}/usr/sbin/pwned-check-pam-enable-dry-run
test -x %{buildroot}/usr/sbin/pwned-check-pam-enable-enforce
test -x %{buildroot}/usr/sbin/pwned-check-pam-disable
test -f %{buildroot}/lib64/security/pam_pwned_check.so
test ! -x %{buildroot}/lib64/security/pam_pwned_check.so
test -x %{buildroot}/usr/share/pwned-check/authselect/enable-authselect.sh
test -x %{buildroot}/usr/share/pwned-check/authselect/rollback-authselect.sh
test -f %{buildroot}/usr/share/doc/pwned-check/linux-install.md

%post
if command -v authselect >/dev/null 2>&1; then
    echo "pwned-check native PAM installed. Run pwned-check-pam-enable-dry-run to enable dry-run mode."
fi

%files
%license /usr/share/doc/pwned-check/LICENSE
%doc /usr/share/doc/pwned-check/README.md
%doc /usr/share/doc/pwned-check/linux-install.md
%doc /usr/share/doc/pwned-check/logging-policy.md
%doc /usr/share/doc/pwned-check/security-model.md
%doc /usr/share/doc/pwned-check/provider-policy.md
%doc /usr/share/doc/pwned-check/checker-contract.md
/usr/bin/pwned-check
/usr/sbin/pwned-check-pam-enable-dry-run
/usr/sbin/pwned-check-pam-enable-enforce
/usr/sbin/pwned-check-pam-disable
/lib64/security/pam_pwned_check.so
%dir /usr/share/pwned-check
%dir /usr/share/pwned-check/authselect
/usr/share/pwned-check/authselect/enable-authselect.sh
/usr/share/pwned-check/authselect/rollback-authselect.sh

%changelog
* Fri May 01 2026 pwned-check maintainers <noreply@example.invalid> - $RPM_VERSION-1
- Build native PAM RPM package from filesystem-layout artifact.
EOF

rpmbuild \
    --define "_topdir $TOPDIR" \
    --define "_build_id_links none" \
    --define "_source_date_epoch_from_changelog 0" \
    -bb "$TOPDIR/SPECS/$PACKAGE_NAME.spec" >/dev/null

rpm_path="$(find "$TOPDIR/RPMS" -type f -name "$PACKAGE_NAME-$RPM_VERSION-*.rpm" | sort | tail -n 1)"
[ -n "$rpm_path" ] || fail "RPM package was not produced"
rpm_name="$(basename "$rpm_path")"
cp "$rpm_path" "$OUTPUT_DIR/$rpm_name"

metadata="$OUTPUT_DIR/$rpm_name.build-metadata.json"
cat > "$metadata" <<EOF
{
  "version": "$VERSION",
  "rpm_version": "$RPM_VERSION",
  "rpm_arch": "$RPM_ARCH",
  "package": "$rpm_name",
  "source_artifact": "$artifact_name.tar.gz",
  "build_time": "$BUILD_TIME"
}
EOF

if command -v sha256sum >/dev/null 2>&1; then
    (
        cd "$OUTPUT_DIR"
        sha256sum "$rpm_name" > "$rpm_name.sha256"
        sha256sum "$(basename "$metadata")" > "$(basename "$metadata").sha256"
    )
else
    (
        cd "$OUTPUT_DIR"
        shasum -a 256 "$rpm_name" | awk '{print $1 "  " $2}' > "$rpm_name.sha256"
        shasum -a 256 "$(basename "$metadata")" | awk '{print $1 "  " $2}' > "$(basename "$metadata").sha256"
    )
fi

printf '%s\n' "$rpm_name"
