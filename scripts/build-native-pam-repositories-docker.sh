#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INPUT_DIR="$ROOT/dist/release"
OUTPUT_ROOT="$ROOT/dist"
STAGE_DIR="${PWNED_CHECK_REPOSITORY_DOCKER_STAGE:-$HOME/pwned-check-repository-build}"
KEY_DIR="${PWNED_CHECK_SIGNING_KEY_DIR:-$HOME/.pwned-check/signing/keys}"
OPENPGP_KEY_FILE="${PWNED_CHECK_OPENPGP_KEY_FILE:-pwned-check-openpgp-production.asc}"
OPENPGP_SECRET_KEY_FILE="${PWNED_CHECK_OPENPGP_SECRET_KEY_FILE:-}"
OPENPGP_FINGERPRINT_FILE="${PWNED_CHECK_OPENPGP_FINGERPRINT_FILE:-pwned-check-openpgp-production.fingerprint.txt}"
OPENPGP_PASSPHRASE_FILE="${PWNED_CHECK_OPENPGP_PASSPHRASE_FILE:-pwned-check-openpgp-passphrase.txt}"
ALPINE_KEY_FILE="${PWNED_CHECK_ALPINE_KEY_FILE:-pwned-check-alpine-production.rsa}"
ALPINE_PUBLIC_KEY_FILE="${PWNED_CHECK_ALPINE_PUBLIC_KEY_FILE:-pwned-check-alpine-production.rsa.pub}"
GITHUB_REPO="${PWNED_CHECK_GITHUB_REPO:-phillipmcmahon/pwned-check}"
VERSION=""
DOWNLOAD_RELEASE_ASSETS=0
DOCKER_PLATFORM="${PWNED_CHECK_REPOSITORY_DOCKER_PLATFORM:-linux/amd64}"

usage() {
    cat <<'EOF'
Usage: scripts/build-native-pam-repositories-docker.sh [OPTIONS]

Generate all signed native PAM package repositories from release artifacts using
Docker containers with a macOS-safe staging directory and read-only signing-key
mounts.

Options:
  --version <tag>              Release tag, required with --download-release-assets
  --download-release-assets    Download immutable GitHub Release assets first
  --input-dir <path>           Directory containing release package artifacts
                               (default: dist/release)
  --output-root <path>         Output root for generated repositories
                               (default: dist)
  --stage-dir <path>           Docker-shareable staging directory
                               (default: ~/pwned-check-repository-build)
  --key-dir <path>             Directory containing signing key material
                               (default: ~/.pwned-check/signing/keys)
  --docker-platform <platform> Docker platform for repository-tool containers
                               (default: linux/amd64)
  --github-repo <owner/name>   GitHub repository used for release downloads
                               (default: phillipmcmahon/pwned-check)
  --help                      Show this help text

Environment overrides:
  PWNED_CHECK_REPOSITORY_DOCKER_STAGE
  PWNED_CHECK_SIGNING_KEY_DIR
  PWNED_CHECK_REPOSITORY_DOCKER_PLATFORM
  PWNED_CHECK_OPENPGP_KEY_FILE
  PWNED_CHECK_OPENPGP_SECRET_KEY_FILE
  PWNED_CHECK_OPENPGP_FINGERPRINT_FILE
  PWNED_CHECK_OPENPGP_PASSPHRASE_FILE
  PWNED_CHECK_ALPINE_KEY_FILE
  PWNED_CHECK_ALPINE_PUBLIC_KEY_FILE
  PWNED_CHECK_GITHUB_REPO
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
        --download-release-assets)
            DOWNLOAD_RELEASE_ASSETS=1
            shift
            ;;
        --input-dir)
            [ "$#" -ge 2 ] || fail "--input-dir requires a value"
            INPUT_DIR="$2"
            shift 2
            ;;
        --output-root)
            [ "$#" -ge 2 ] || fail "--output-root requires a value"
            OUTPUT_ROOT="$2"
            shift 2
            ;;
        --stage-dir)
            [ "$#" -ge 2 ] || fail "--stage-dir requires a value"
            STAGE_DIR="$2"
            shift 2
            ;;
        --key-dir)
            [ "$#" -ge 2 ] || fail "--key-dir requires a value"
            KEY_DIR="$2"
            shift 2
            ;;
        --docker-platform)
            [ "$#" -ge 2 ] || fail "--docker-platform requires a value"
            DOCKER_PLATFORM="$2"
            shift 2
            ;;
        --github-repo)
            [ "$#" -ge 2 ] || fail "--github-repo requires a value"
            GITHUB_REPO="$2"
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

require_command docker
require_command rsync

if [ "$DOWNLOAD_RELEASE_ASSETS" -eq 1 ]; then
    [ -n "$VERSION" ] || fail "--version is required with --download-release-assets"
    require_command gh
    rm -rf "$INPUT_DIR"
    mkdir -p "$INPUT_DIR"
    gh release download "$VERSION" --repo "$GITHUB_REPO" --dir "$INPUT_DIR" --clobber
fi

[ -d "$INPUT_DIR" ] || fail "input directory does not exist: $INPUT_DIR"
find "$INPUT_DIR" -maxdepth 1 -type f \( -name '*.deb' -o -name '*.rpm' -o -name '*.apk' -o -name '*.pkg.tar.zst' \) | grep -q . \
    || fail "input directory contains no native package artifacts: $INPUT_DIR"

[ -d "$KEY_DIR" ] || fail "signing key directory does not exist: $KEY_DIR"
[ -f "$KEY_DIR/$OPENPGP_KEY_FILE" ] || fail "OpenPGP key file missing: $KEY_DIR/$OPENPGP_KEY_FILE"
[ -f "$KEY_DIR/$OPENPGP_FINGERPRINT_FILE" ] || fail "OpenPGP fingerprint file missing: $KEY_DIR/$OPENPGP_FINGERPRINT_FILE"
[ -f "$KEY_DIR/$OPENPGP_PASSPHRASE_FILE" ] || fail "OpenPGP passphrase file missing: $KEY_DIR/$OPENPGP_PASSPHRASE_FILE"
[ -f "$KEY_DIR/$ALPINE_KEY_FILE" ] || fail "Alpine signing key missing: $KEY_DIR/$ALPINE_KEY_FILE"
[ -f "$KEY_DIR/$ALPINE_PUBLIC_KEY_FILE" ] || fail "Alpine public key missing: $KEY_DIR/$ALPINE_PUBLIC_KEY_FILE"

OPENPGP_KEY_ID="$(awk 'NF {print $1; exit}' "$KEY_DIR/$OPENPGP_FINGERPRINT_FILE")"
[ -n "$OPENPGP_KEY_ID" ] || fail "OpenPGP fingerprint file is empty: $KEY_DIR/$OPENPGP_FINGERPRINT_FILE"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/repo" "$STAGE_DIR/release" "$STAGE_DIR/out" "$STAGE_DIR/keys"
cleanup_sensitive_stage() {
    rm -f "$STAGE_DIR/keys/openpgp-secret.asc"
}
trap cleanup_sensitive_stage EXIT INT TERM

if [ -n "$OPENPGP_SECRET_KEY_FILE" ]; then
    [ -f "$OPENPGP_SECRET_KEY_FILE" ] || fail "OpenPGP secret key file does not exist: $OPENPGP_SECRET_KEY_FILE"
    cp "$OPENPGP_SECRET_KEY_FILE" "$STAGE_DIR/keys/openpgp-secret.asc"
else
    require_command gpg
    gpg --batch --yes --pinentry-mode loopback \
        --passphrase-file "$KEY_DIR/$OPENPGP_PASSPHRASE_FILE" \
        --armor --export-secret-keys "$OPENPGP_KEY_ID" \
        > "$STAGE_DIR/keys/openpgp-secret.asc"
fi
chmod 0600 "$STAGE_DIR/keys/openpgp-secret.asc"

rsync -a --delete "$ROOT/scripts/" "$STAGE_DIR/repo/scripts/"
rsync -a --delete "$INPUT_DIR/" "$STAGE_DIR/release/"

docker_run() {
    image="$1"
    shift
    docker run --rm \
        --platform "$DOCKER_PLATFORM" \
        -e OPENPGP_KEY_ID="$OPENPGP_KEY_ID" \
        -e OPENPGP_KEY_FILE="$OPENPGP_KEY_FILE" \
        -e OPENPGP_PASSPHRASE_FILE="$OPENPGP_PASSPHRASE_FILE" \
        -v "$STAGE_DIR:/work" \
        -v "$KEY_DIR:/keys:ro" \
        -w /work/repo \
        "$image" "$@"
}

openpgp_setup='
set -eu
export GNUPGHOME=/tmp/pwned-check-gnupg
rm -rf "$GNUPGHOME"
install -d -m 0700 "$GNUPGHOME"
gpg --batch --import "/keys/$OPENPGP_KEY_FILE" >/dev/null
gpg --batch --import /work/keys/openpgp-secret.asc >/dev/null
'

echo "::group::[repository:apt] build"
docker_run debian:stable-slim sh -lc '
export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends ca-certificates dpkg-dev gnupg gzip coreutils >/dev/null
'"${openpgp_setup}"'
PWNED_CHECK_GPG_PASSPHRASE_FILE="/keys/$OPENPGP_PASSPHRASE_FILE" \
  scripts/build-native-pam-apt-repository.sh \
    --input-dir /work/release \
    --output-dir /work/out/apt-repository \
    --signing-key "$OPENPGP_KEY_ID" \
    --public-key-output /work/out/apt-repository/pwned-check.asc
'
echo "::endgroup::"

echo "::group::[repository:rpm] build"
docker_run fedora:latest sh -lc '
dnf install -y createrepo_c gnupg2 rpm-sign rpm-build >/dev/null
'"${openpgp_setup}"'
PWNED_CHECK_GPG_PASSPHRASE_FILE="/keys/$OPENPGP_PASSPHRASE_FILE" \
  scripts/build-native-pam-rpm-repository.sh \
    --input-dir /work/release \
    --output-dir /work/out/rpm-repository \
    --signing-key "$OPENPGP_KEY_ID" \
    --public-key-output /work/out/rpm-repository/pwned-check.asc
'
echo "::endgroup::"

echo "::group::[repository:arch] build"
docker_run archlinux:base-devel sh -lc '
printf "DisableSandbox\n" >> /etc/pacman.conf
pacman -Sy --noconfirm --needed gnupg pacman-contrib tar zstd >/dev/null
'"${openpgp_setup}"'
PWNED_CHECK_GPG_PASSPHRASE_FILE="/keys/$OPENPGP_PASSPHRASE_FILE" \
  scripts/build-native-pam-arch-repository.sh \
    --input-dir /work/release \
    --output-dir /work/out/arch-repository \
    --signing-key "$OPENPGP_KEY_ID" \
    --public-key-output /work/out/arch-repository/pwned-check.asc
'
echo "::endgroup::"

echo "::group::[repository:alpine] build"
docker_run alpine:latest sh -lc '
set -eu
apk add --no-cache alpine-sdk openssl tar >/dev/null
scripts/build-native-pam-alpine-repository.sh \
  --input-dir /work/release \
  --output-dir /work/out/alpine-repository \
  --signing-key "/keys/'"$ALPINE_KEY_FILE"'" \
  --public-key-output /work/out/alpine-repository/'"$ALPINE_PUBLIC_KEY_FILE"'
'
echo "::endgroup::"

rm -rf "$STAGE_DIR/out/package-repositories"
mkdir -p "$STAGE_DIR/out/package-repositories"
cp -a "$STAGE_DIR/out/apt-repository" "$STAGE_DIR/out/package-repositories/apt"
cp -a "$STAGE_DIR/out/rpm-repository" "$STAGE_DIR/out/package-repositories/rpm"
cp -a "$STAGE_DIR/out/arch-repository" "$STAGE_DIR/out/package-repositories/arch"
cp -a "$STAGE_DIR/out/alpine-repository" "$STAGE_DIR/out/package-repositories/alpine"
cp "$KEY_DIR/$OPENPGP_KEY_FILE" "$STAGE_DIR/out/package-repositories/pwned-check-openpgp-production.asc"
cp "$KEY_DIR/$OPENPGP_FINGERPRINT_FILE" "$STAGE_DIR/out/package-repositories/pwned-check-openpgp-production.fingerprint.txt"
cp "$STAGE_DIR/out/package-repositories/pwned-check-openpgp-production.asc" "$STAGE_DIR/out/package-repositories/apt/pwned-check.asc"
cp "$STAGE_DIR/out/package-repositories/pwned-check-openpgp-production.asc" "$STAGE_DIR/out/package-repositories/rpm/pwned-check.asc"
cp "$STAGE_DIR/out/package-repositories/pwned-check-openpgp-production.asc" "$STAGE_DIR/out/package-repositories/arch/pwned-check.asc"

mkdir -p "$OUTPUT_ROOT"
rm -rf \
    "$OUTPUT_ROOT/apt-repository" \
    "$OUTPUT_ROOT/rpm-repository" \
    "$OUTPUT_ROOT/arch-repository" \
    "$OUTPUT_ROOT/alpine-repository" \
    "$OUTPUT_ROOT/package-repositories"
cp -a "$STAGE_DIR/out/apt-repository" "$OUTPUT_ROOT/apt-repository"
cp -a "$STAGE_DIR/out/rpm-repository" "$OUTPUT_ROOT/rpm-repository"
cp -a "$STAGE_DIR/out/arch-repository" "$OUTPUT_ROOT/arch-repository"
cp -a "$STAGE_DIR/out/alpine-repository" "$OUTPUT_ROOT/alpine-repository"
cp -a "$STAGE_DIR/out/package-repositories" "$OUTPUT_ROOT/package-repositories"

echo "Repository build complete"
echo "Family outputs:"
echo "  $OUTPUT_ROOT/apt-repository"
echo "  $OUTPUT_ROOT/rpm-repository"
echo "  $OUTPUT_ROOT/arch-repository"
echo "  $OUTPUT_ROOT/alpine-repository"
echo "Publishable GitHub Pages tree:"
echo "  $OUTPUT_ROOT/package-repositories"
cleanup_sensitive_stage
trap - EXIT INT TERM
