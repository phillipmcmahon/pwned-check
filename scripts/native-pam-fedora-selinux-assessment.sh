#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT_ROOT="${PWNED_CHECK_TEST_OUTPUT_DIR:-$ROOT/.test-output/native-pam-fedora-selinux-assessment}"
STAMP="$(date -u '+%Y%m%dT%H%M%SZ')"
RUN_DIR="$OUTPUT_ROOT/${STAMP}-native-pam-fedora-selinux-assessment"
COMBINED="$RUN_DIR/native-pam-fedora-selinux-assessment.txt"
AVC_LOG="$RUN_DIR/avc-after-smoke.txt"
SMOKE_LOG="$RUN_DIR/fedora-rpm-package-smoke.txt"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-fedora-selinux-assessment.sh

Run the Fedora/RHEL native PAM RPM package smoke while capturing SELinux mode,
authselect state, audit AVCs, and a combined text report under .test-output/.

The assessment fails if the smoke fails or if matching SELinux AVCs mention
pwned-check, pam_pwned_check, the Fedora host smoke service, or the smoke
checker path.

Environment:
  PWNED_CHECK_TEST_OUTPUT_DIR            Override output root
  NATIVE_PAM_FEDORA_RPM_SMOKE_VERSION   Version label for the smoke package
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

append_section() {
    title="$1"
    {
        printf '\n## %s\n\n' "$title"
        cat
    } >>"$COMBINED"
}

run_capture() {
    title="$1"
    shift
    {
        printf '$'
        for arg in "$@"; do
            printf ' %s' "$arg"
        done
        printf '\n'
        "$@" 2>&1 || true
    } | append_section "$title"
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

[ "$(uname -s)" = "Linux" ] || {
    echo "native PAM Fedora SELinux assessment skipped: Linux host required"
    exit 0
}

if [ -r /etc/os-release ]; then
    OS_ID="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
    OS_ID_LIKE="$(sed -n 's/^ID_LIKE=//p' /etc/os-release | tr -d '"')"
    case " $OS_ID $OS_ID_LIKE " in
        *" fedora "*|*" rhel "*|*" centos "*) ;;
        *) fail "SELinux assessment currently supports Fedora/RHEL-family hosts only, got ID=${OS_ID:-unknown}" ;;
    esac
fi

require_command make
if [ "$(id -u)" -ne 0 ]; then
    require_command sudo
fi

mkdir -p "$RUN_DIR"
ln -sfn "$RUN_DIR" "$OUTPUT_ROOT/latest"

START_EPOCH="$(date +%s)"
START_AUSEARCH_DATE="$(date '+%m/%d/%y')"
START_AUSEARCH_TIME="$(date '+%H:%M:%S')"
START_AUSEARCH="$START_AUSEARCH_DATE $START_AUSEARCH_TIME"
SELINUX_MODE="unknown"
if command -v getenforce >/dev/null 2>&1; then
    SELINUX_MODE="$(getenforce 2>/dev/null || printf unknown)"
fi

{
    printf '# Native PAM Fedora SELinux Assessment\n\n'
    printf 'Started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Repository: %s\n' "$ROOT"
    printf 'SELinux mode: %s\n' "$SELINUX_MODE"
    printf 'Audit search start: %s\n' "$START_AUSEARCH"
} >"$COMBINED"

run_capture "OS Release" cat /etc/os-release
run_capture "Kernel" uname -a
if command -v getenforce >/dev/null 2>&1; then
    run_capture "SELinux getenforce" getenforce
else
    printf '\n## SELinux getenforce\n\ngetenforce not installed\n' >>"$COMBINED"
fi
if command -v sestatus >/dev/null 2>&1; then
    run_capture "SELinux sestatus" sestatus
else
    printf '\n## SELinux sestatus\n\nsestatus not installed\n' >>"$COMBINED"
fi
if command -v id >/dev/null 2>&1; then
    run_capture "SELinux current context" id -Z
fi
if command -v authselect >/dev/null 2>&1; then
    run_capture "Authselect before smoke" authselect current -r
fi

set +e
(
    cd "$ROOT"
    make native-pam-fedora-rpm-package-smoke
) >"$SMOKE_LOG" 2>&1
SMOKE_RC="$?"
set -e
cat "$SMOKE_LOG" | append_section "Fedora RPM package smoke"

if command -v authselect >/dev/null 2>&1; then
    run_capture "Authselect after smoke" authselect current -r
fi

if command -v ausearch >/dev/null 2>&1; then
    AUSEARCH_ERROR=0
    set +e
    as_root ausearch -m AVC,USER_AVC -ts "$START_AUSEARCH_DATE" "$START_AUSEARCH_TIME" >"$AVC_LOG" 2>&1
    AUSEARCH_RC="$?"
    set -e
    if [ "$AUSEARCH_RC" -ne 0 ] && grep -F '<no matches>' "$AVC_LOG" >/dev/null 2>&1; then
        :
    elif [ "$AUSEARCH_RC" -ne 0 ] && grep -F 'no matches' "$AVC_LOG" >/dev/null 2>&1; then
        :
    elif [ "$AUSEARCH_RC" -ne 0 ]; then
        printf 'ausearch exited with rc=%s\n' "$AUSEARCH_RC" >>"$AVC_LOG"
        AUSEARCH_ERROR=1
    fi
    cat "$AVC_LOG" | append_section "SELinux AVCs after smoke"
else
    AUSEARCH_ERROR=1
    printf 'ausearch not installed\n' >"$AVC_LOG"
    cat "$AVC_LOG" | append_section "SELinux AVCs after smoke"
fi

MATCHING_AVCS="$RUN_DIR/matching-avcs.txt"
if grep -Ei 'pwned-check|pam_pwned_check|pwned_check|native-fedora-host|fedora-host-package-smoke' "$AVC_LOG" >"$MATCHING_AVCS"; then
    MATCHING_AVC_COUNT="$(wc -l <"$MATCHING_AVCS" | tr -d ' ')"
else
    MATCHING_AVC_COUNT=0
fi

{
    printf '\n## Assessment Summary\n\n'
    printf 'Smoke result: %s\n' "$SMOKE_RC"
    printf 'SELinux mode: %s\n' "$SELINUX_MODE"
    printf 'Matching AVC lines: %s\n' "$MATCHING_AVC_COUNT"
    printf 'Output directory: %s\n' "$RUN_DIR"
    printf 'Completed: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} >>"$COMBINED"

if [ "$SMOKE_RC" -ne 0 ]; then
    printf 'Native PAM Fedora SELinux assessment failed: smoke rc=%s\n' "$SMOKE_RC" >&2
    printf 'Report: %s\n' "$COMBINED" >&2
    exit "$SMOKE_RC"
fi

if [ "$AUSEARCH_ERROR" -ne 0 ]; then
    printf 'Native PAM Fedora SELinux assessment failed: AVC capture did not complete cleanly\n' >&2
    printf 'Report: %s\n' "$COMBINED" >&2
    exit 1
fi

if [ "$MATCHING_AVC_COUNT" -ne 0 ]; then
    printf 'Native PAM Fedora SELinux assessment failed: matching AVCs found\n' >&2
    printf 'Report: %s\n' "$COMBINED" >&2
    exit 1
fi

if [ "$SELINUX_MODE" != "Enforcing" ]; then
    printf 'Native PAM Fedora SELinux assessment passed with SELinux mode=%s; enforcing-mode validation is still required before production release.\n' "$SELINUX_MODE"
else
    printf 'Native PAM Fedora SELinux assessment passed in enforcing mode.\n'
fi
printf 'Report: %s\n' "$COMBINED"
