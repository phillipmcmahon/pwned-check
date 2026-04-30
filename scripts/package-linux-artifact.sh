#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-linux-artifact.sh --version <version> --goarch <arch> [OPTIONS]

Build a Linux release tarball containing pwned-check, pwned-check-pam-helper,
install.sh, README.md, LICENSE, and build metadata.

Options:
  --version <version>      Release version, for example 0.2.0 or dev-abcdef12
  --goarch <arch>          Go architecture, usually amd64 or arm64
  --goos <os>              Go OS target (default: linux)
  --output-dir <path>      Output directory (default: dist/release)
  --build-time <time>      RFC3339 build time (default: current UTC time)
  --help                   Show this help text
EOF
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
GOOS_VALUE="linux"
GOARCH_VALUE=""
OUTPUT_DIR="$ROOT/dist/release"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || fail "--version requires a value"
      VERSION="$2"
      shift 2
      ;;
    --goos)
      [ "$#" -ge 2 ] || fail "--goos requires a value"
      GOOS_VALUE="$2"
      shift 2
      ;;
    --goarch)
      [ "$#" -ge 2 ] || fail "--goarch requires a value"
      GOARCH_VALUE="$2"
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
[ -n "$GOARCH_VALUE" ] || fail "--goarch is required"
[ "$GOOS_VALUE" = "linux" ] || fail "only linux packaging is currently supported"

case "$GOARCH_VALUE" in
  amd64|arm64)
    ;;
  *)
    fail "unsupported linux architecture: $GOARCH_VALUE"
    ;;
esac

command -v go >/dev/null 2>&1 || fail "go not found"
command -v tar >/dev/null 2>&1 || fail "tar not found"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-package.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

BASENAME="pwned-check_${VERSION}_${GOOS_VALUE}_${GOARCH_VALUE}"
PACKAGE_DIR="$WORK_DIR/$BASENAME"
mkdir -p "$PACKAGE_DIR/metadata"

LDFLAGS="-X github.com/phillipmcmahon/pwned-check/internal/pwned.Version=$VERSION"
GOAMD64_VALUE=""
if [ "$GOARCH_VALUE" = "amd64" ]; then
  GOAMD64_VALUE="${GOAMD64:-v1}"
fi

(
  cd "$ROOT"
  CGO_ENABLED=0 GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" go build -trimpath -ldflags "$LDFLAGS" -o "$PACKAGE_DIR/pwned-check" ./cmd/pwned-check
  CGO_ENABLED=0 GOOS="$GOOS_VALUE" GOARCH="$GOARCH_VALUE" GOAMD64="$GOAMD64_VALUE" go build -trimpath -o "$PACKAGE_DIR/pwned-check-pam-helper" ./cmd/pwned-check-pam-helper
  cp README.md LICENSE "$PACKAGE_DIR/"
  go version -m "$PACKAGE_DIR/pwned-check" > "$PACKAGE_DIR/metadata/pwned-check-go-version.txt"
  go version -m "$PACKAGE_DIR/pwned-check-pam-helper" > "$PACKAGE_DIR/metadata/pwned-check-pam-helper-go-version.txt"
  go list -m all > "$PACKAGE_DIR/metadata/go-modules.txt"
)

cat > "$PACKAGE_DIR/metadata/build.json" <<EOF
{
  "version": "$VERSION",
  "goos": "$GOOS_VALUE",
  "goarch": "$GOARCH_VALUE",
  "build_time": "$BUILD_TIME"
}
EOF

cat > "$PACKAGE_DIR/install.sh" <<EOF
#!/bin/sh
set -eu

INSTALL_ROOT="\${INSTALL_ROOT:-/usr/local/lib/pwned-check}"
BIN_DIR="\${BIN_DIR:-/usr/local/bin}"
VERSION="$VERSION"
ARCH="$GOARCH_VALUE"

mkdir -p "\$INSTALL_ROOT" "\$BIN_DIR"
install -m 0755 ./pwned-check "\$INSTALL_ROOT/pwned-check_\${VERSION}_linux_\${ARCH}"
install -m 0755 ./pwned-check-pam-helper "\$INSTALL_ROOT/pwned-check-pam-helper_\${VERSION}_linux_\${ARCH}"
ln -sfn "\$INSTALL_ROOT/pwned-check_\${VERSION}_linux_\${ARCH}" "\$INSTALL_ROOT/current"
ln -sfn "\$INSTALL_ROOT/pwned-check-pam-helper_\${VERSION}_linux_\${ARCH}" "\$INSTALL_ROOT/current-pam-helper"
ln -sfn "\$INSTALL_ROOT/current" "\$BIN_DIR/pwned-check"
ln -sfn "\$INSTALL_ROOT/current-pam-helper" "\$BIN_DIR/pwned-check-pam-helper"

"\$BIN_DIR/pwned-check" --version
"\$BIN_DIR/pwned-check-pam-helper" --version
EOF
chmod 0755 "$PACKAGE_DIR/install.sh"

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
