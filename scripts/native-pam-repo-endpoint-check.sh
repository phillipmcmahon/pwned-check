#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"

BASE_URL="${PWNED_CHECK_REPO_BASE_URL:-https://phillipmcmahon.github.io/pwned-check}"
PACKAGE_NAME="pwned-check-native-pam"
OPENPGP_FPR="BDF6F4DD343E9F10EA9DB510FDDA2848A95AD641"
ALPINE_KEY_SHA256="8CC2BD76F364D3734C8A265B152FCEFFA6F3B90FC2857DB92D40BED4808F214F"

usage() {
    cat <<'EOF'
Usage: scripts/native-pam-repo-endpoint-check.sh [OPTIONS]

Validate published native PAM repository endpoints without installing packages
or mutating a host PAM stack. The check is safe for scheduled GitHub Actions:
it verifies public-key availability, signed metadata, repository indexes, and
package visibility for apt, RPM, Arch, and Alpine endpoints.

Options:
  --base-url <url>  Repository root
                    (default: https://phillipmcmahon.github.io/pwned-check)
  --help           Show this help text

Environment:
  PWNED_CHECK_REPO_BASE_URL  Default repository root
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --base-url)
            [ "$#" -ge 2 ] || fail "--base-url requires a value"
            BASE_URL="${2%/}"
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
BASE_URL="${BASE_URL%/}"

require_command awk
require_command curl
require_command gpg
require_command gzip
require_command openssl
require_command sha256sum
require_command tar
require_command zstd

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-repo-endpoint.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

fetch() {
    url="$1"
    output="$2"
    curl --fail --show-error --silent --location --retry 3 --retry-delay 2 "$url" --output "$output"
}

assert_contains() {
    file="$1"
    pattern="$2"
    grep -F "$pattern" "$file" >/dev/null || fail "$file does not contain expected text: $pattern"
}

openpgp_key="$work_dir/pwned-check-openpgp-production.asc"
alpine_key="$work_dir/pwned-check-alpine-production.rsa.pub"
fetch "$BASE_URL/pwned-check-openpgp-production.asc" "$openpgp_key"
fetch "$BASE_URL/alpine/pwned-check-alpine-production.rsa.pub" "$alpine_key"

keyring="$work_dir/repo-signing.gpg"
gpg --batch --no-default-keyring --keyring "$keyring" --import "$openpgp_key" >/dev/null 2>&1
actual_fpr="$(gpg --batch --no-default-keyring --keyring "$keyring" --with-colons --list-keys | awk -F: '$1 == "fpr" {print $10; exit}')"
[ "$actual_fpr" = "$OPENPGP_FPR" ] || fail "OpenPGP fingerprint mismatch: got $actual_fpr"

actual_alpine_fpr="$(sha256sum "$alpine_key" | awk '{print toupper($1)}')"
[ "$actual_alpine_fpr" = "$ALPINE_KEY_SHA256" ] || fail "Alpine RSA key SHA256 mismatch: got $actual_alpine_fpr"

check_apt() {
    echo "::group::[repo-endpoint:apt]"
    apt_dir="$work_dir/apt"
    mkdir -p "$apt_dir"
    fetch "$BASE_URL/apt/dists/stable/InRelease" "$apt_dir/InRelease"
    fetch "$BASE_URL/apt/dists/stable/Release" "$apt_dir/Release"
    fetch "$BASE_URL/apt/dists/stable/Release.gpg" "$apt_dir/Release.gpg"

    gpg --batch --no-default-keyring --keyring "$keyring" --verify "$apt_dir/InRelease" >/dev/null 2>&1 || fail "apt InRelease signature verification failed"
    gpg --batch --no-default-keyring --keyring "$keyring" --verify "$apt_dir/Release.gpg" "$apt_dir/Release" >/dev/null 2>&1 || fail "apt Release.gpg signature verification failed"
    assert_contains "$apt_dir/Release" "Architectures: amd64 arm64"
    assert_contains "$apt_dir/Release" "Components: main"

    for arch in amd64 arm64; do
        packages_gz="$apt_dir/Packages-$arch.gz"
        packages="$apt_dir/Packages-$arch"
        fetch "$BASE_URL/apt/dists/stable/main/binary-$arch/Packages.gz" "$packages_gz"
        gzip -dc "$packages_gz" > "$packages"
        assert_contains "$packages" "Package: $PACKAGE_NAME"
        assert_contains "$packages" "Architecture: $arch"
        filename="$(awk '/^Filename: / {print $2; exit}' "$packages")"
        [ -n "$filename" ] || fail "apt Packages for $arch does not include Filename"
        curl --fail --silent --show-error --location --head "$BASE_URL/apt/$filename" >/dev/null || fail "apt package payload missing: $filename"
    done
    echo "apt endpoint passed"
    echo "::endgroup::"
}

check_rpm() {
    echo "::group::[repo-endpoint:rpm]"
    rpm_dir="$work_dir/rpm"
    mkdir -p "$rpm_dir"
    fetch "$BASE_URL/rpm/repodata/repomd.xml" "$rpm_dir/repomd.xml"
    fetch "$BASE_URL/rpm/repodata/repomd.xml.asc" "$rpm_dir/repomd.xml.asc"
    gpg --batch --no-default-keyring --keyring "$keyring" --verify "$rpm_dir/repomd.xml.asc" "$rpm_dir/repomd.xml" >/dev/null 2>&1 || fail "RPM repomd.xml signature verification failed"

    primary_href="$(sed -n 's/.*<location href="\([^"]*primary.xml.zst\)".*/\1/p' "$rpm_dir/repomd.xml" | head -n 1)"
    primary_sha="$(awk '
        /<data type="primary">/ { in_primary = 1 }
        in_primary && /<checksum type="sha256">/ {
            line = $0
            sub(/.*<checksum type="sha256">/, "", line)
            marker = "</checksum>"
            print substr(line, 1, index(line, marker) - 1)
            exit
        }
        in_primary && index($0, "</data>") { in_primary = 0 }
    ' "$rpm_dir/repomd.xml")"
    [ -n "$primary_href" ] || fail "RPM primary metadata href missing"
    [ -n "$primary_sha" ] || fail "RPM primary metadata checksum missing"
    primary_zst="$rpm_dir/primary.xml.zst"
    primary_xml="$rpm_dir/primary.xml"
    fetch "$BASE_URL/rpm/$primary_href" "$primary_zst"
    printf '%s  %s\n' "$primary_sha" "$primary_zst" | sha256sum -c >/dev/null || fail "RPM primary metadata checksum mismatch"
    zstd -dc "$primary_zst" > "$primary_xml"
    assert_contains "$primary_xml" "<name>$PACKAGE_NAME</name>"
    assert_contains "$primary_xml" "<arch>x86_64</arch>"
    assert_contains "$primary_xml" "<arch>aarch64</arch>"
    echo "rpm endpoint passed"
    echo "::endgroup::"
}

check_arch() {
    echo "::group::[repo-endpoint:arch]"
    arch_dir="$work_dir/arch"
    mkdir -p "$arch_dir"
    fetch "$BASE_URL/arch/x86_64/pwned-check.db" "$arch_dir/pwned-check.db"
    fetch "$BASE_URL/arch/x86_64/pwned-check.db.sig" "$arch_dir/pwned-check.db.sig"
    gpg --batch --no-default-keyring --keyring "$keyring" --verify "$arch_dir/pwned-check.db.sig" "$arch_dir/pwned-check.db" >/dev/null 2>&1 || fail "Arch repository database signature verification failed"
    tar -tf "$arch_dir/pwned-check.db" | grep -F "$PACKAGE_NAME" >/dev/null || fail "Arch repository database does not list $PACKAGE_NAME"
    tar -xOf "$arch_dir/pwned-check.db" "*/desc" > "$arch_dir/desc"
    assert_contains "$arch_dir/desc" "$PACKAGE_NAME"
    assert_contains "$arch_dir/desc" "x86_64"
    echo "arch endpoint passed"
    echo "::endgroup::"
}

check_alpine() {
    echo "::group::[repo-endpoint:alpine]"
    alpine_dir="$work_dir/alpine"
    mkdir -p "$alpine_dir"
    fetch "$BASE_URL/alpine/aarch64/APKINDEX.tar.gz" "$alpine_dir/APKINDEX.tar.gz"
    tar -tzf "$alpine_dir/APKINDEX.tar.gz" > "$alpine_dir/list"
    grep -E '^\.SIGN\.RSA\.' "$alpine_dir/list" >/dev/null || fail "Alpine APKINDEX is missing embedded RSA signature entry"
    tar -xzf "$alpine_dir/APKINDEX.tar.gz" -C "$alpine_dir"
    alpine_sig="$(find "$alpine_dir" -name '.SIGN.RSA.*' -print -quit)"
    [ -n "$alpine_sig" ] || fail "Alpine APKINDEX signature entry could not be extracted"
    assert_contains "$alpine_dir/APKINDEX" "P:$PACKAGE_NAME"
    assert_contains "$alpine_dir/APKINDEX" "A:aarch64"
    echo "alpine endpoint passed"
    echo "::endgroup::"
}

check_apt
check_rpm
check_arch
check_alpine

echo "Native PAM repository endpoint check passed"
