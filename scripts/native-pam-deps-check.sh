#!/bin/sh

set -eu

SO_PATH="${1:-dist/pam_pwned_check.so}"

fail() {
    echo "Error: $*" >&2
    exit 1
}

[ -f "$SO_PATH" ] || fail "shared object not found: $SO_PATH"

if command -v ldd >/dev/null 2>&1; then
    DEPS="$(ldd "$SO_PATH")"
elif command -v otool >/dev/null 2>&1; then
    echo "native PAM dependency allowlist check skipped: ldd is not available on this platform" >&2
    exit 0
else
    echo "native PAM dependency allowlist check skipped: no supported dynamic dependency tool found" >&2
    exit 0
fi

printf '%s\n' "$DEPS" | awk '
    /=>/ { print $1; next }
    /^[[:space:]]*\// { n=$1; sub(".*/", "", n); print n; next }
    /^[[:space:]]*linux-vdso/ { print $1; next }
' | while IFS= read -r dep; do
    case "$dep" in
        ""|linux-vdso.so.*|ld-linux*.so.*|ld-musl-*.so.*|libc.so.*|libgcc_s.so.*|libdl.so.*|libpthread.so.*|libm.so.*|libpam.so.*|libaudit.so.*|libcap-ng.so.*)
            ;;
        *)
            printf '%s\n' "$DEPS" >&2
            fail "unexpected native PAM shared-library dependency: $dep"
            ;;
    esac
done

echo "native PAM dependency allowlist passed"
