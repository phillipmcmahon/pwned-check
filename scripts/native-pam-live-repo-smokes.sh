#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$ROOT/scripts/lib/release-helpers.sh"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-live-repo-smokes}"

if capture_or_reexec "$OUTPUT_ROOT" "native-pam-live-repo-smokes" \
    "PWNED_CHECK_LIVE_REPO_SMOKES_NO_CAPTURE" \
    "Native PAM live repository smoke output" "$0" "$@"; then
    :
fi

APT_URL="${PWNED_CHECK_APT_REPO_URL:-https://phillipmcmahon.github.io/pwned-check/apt}"
RPM_URL="${PWNED_CHECK_RPM_REPO_URL:-https://phillipmcmahon.github.io/pwned-check/rpm}"
ARCH_URL="${PWNED_CHECK_ARCH_REPO_URL:-https://phillipmcmahon.github.io/pwned-check/arch}"
ALPINE_URL="${PWNED_CHECK_ALPINE_REPO_URL:-https://phillipmcmahon.github.io/pwned-check/alpine}"

APT_HOSTS="${PWNED_CHECK_APT_REPO_SMOKE_HOSTS:-codex-vm-ubuntu codex-vm-debian codex-vm-ubuntu-arm64 codex-vm-debian-arm64}"
RPM_HOSTS="${PWNED_CHECK_RPM_REPO_SMOKE_HOSTS:-codex-vm-fedora codex-vm-rocky}"
ARCH_HOSTS="${PWNED_CHECK_ARCH_REPO_SMOKE_HOSTS:-codex-vm-arch}"
ALPINE_HOSTS="${PWNED_CHECK_ALPINE_REPO_SMOKE_HOSTS:-codex-vm-alpine-arm64}"

run_for_hosts() {
    label="$1"
    script="$2"
    url="$3"
    hosts="$4"

    [ -n "$hosts" ] || fail "$label live repository smoke host list is empty"
    for host in $hosts; do
        echo "::group::[live-repo:$label] $host"
        "$script" --host "$host" --repo-url "$url"
        echo "::endgroup::"
    done
}

run_for_hosts "apt" "$ROOT/scripts/native-pam-apt-repo-smoke.sh" "$APT_URL" "$APT_HOSTS"
run_for_hosts "rpm" "$ROOT/scripts/native-pam-rpm-repo-smoke.sh" "$RPM_URL" "$RPM_HOSTS"
run_for_hosts "arch" "$ROOT/scripts/native-pam-arch-repo-smoke.sh" "$ARCH_URL" "$ARCH_HOSTS"

run_for_hosts "alpine" "$ROOT/scripts/native-pam-alpine-repo-smoke.sh" "$ALPINE_URL" "$ALPINE_HOSTS"

echo "Native PAM live repository smoke gate complete"
