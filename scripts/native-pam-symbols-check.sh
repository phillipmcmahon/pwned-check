#!/bin/sh

set -eu

SO_PATH="${1:-dist/pam_pwned_check.so}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

[ -f "$SO_PATH" ] || fail "shared object not found: $SO_PATH"

if command -v nm >/dev/null 2>&1; then
    SYMBOLS="$(nm -D "$SO_PATH" 2>/dev/null || nm -g "$SO_PATH")"
elif command -v objdump >/dev/null 2>&1; then
    SYMBOLS="$(objdump -T "$SO_PATH")"
else
    echo "native PAM symbol check skipped: neither nm nor objdump is available" >&2
    exit 0
fi

for symbol in \
    pam_sm_authenticate \
    pam_sm_setcred \
    pam_sm_acct_mgmt \
    pam_sm_open_session \
    pam_sm_close_session \
    pam_sm_chauthtok
do
    printf '%s\n' "$SYMBOLS" | awk '{print $NF}' | grep -Fx "$symbol" >/dev/null 2>&1 || {
        printf '%s\n' "$SYMBOLS" >&2
        fail "missing exported PAM symbol: $symbol"
    }
done

echo "native PAM exported symbol check passed"

