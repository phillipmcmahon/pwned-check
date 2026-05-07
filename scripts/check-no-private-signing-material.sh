#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/check-no-private-signing-material.sh <path> [<path> ...]

Fail if private signing material or passphrase-like files are present under
the supplied paths. This guard is intended for repository checkouts, release
asset staging directories, generated public repository trees, and publication
trees.
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

if [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
fi

armor_begin='-----BEGIN '
armor_end='-----'
private_key_re="${armor_begin}"'[A-Z0-9 ]*PRIVATE KEY( BLOCK)?'"${armor_end}"
encrypted_secret_re="${armor_begin}"'AGE-ENCRYPTED FILE'"${armor_end}"
violation_count=0

report_violation() {
    path="$1"
    reason="$2"
    printf 'private signing material guard violation: %s: %s\n' "$path" "$reason" >&2
    violation_count=$((violation_count + 1))
}

check_path_name() {
    path="$1"
    name="$(basename -- "$path")"
    lower_name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"

    case "$name" in
        .git|.hg|.svn|target|dist|.venv|node_modules)
            return 1
            ;;
    esac

    case "$lower_name" in
        .gnupg|gnupg|gpg-agent.conf|private-keys-v1.d|*.kbx|secring*)
            report_violation "$path" "GnuPG private-key storage path is not allowed"
            ;;
        *passphrase*)
            report_violation "$path" "passphrase-like file or directory name is not allowed"
            ;;
        openpgp-secret.asc|*secret-key*)
            report_violation "$path" "secret-key-like file or directory name is not allowed"
            ;;
        *.rsa)
            report_violation "$path" "Alpine RSA private key filename is not allowed"
            ;;
    esac

    return 0
}

check_file_content() {
    path="$1"

    if grep -Iq . "$path" 2>/dev/null; then
        if LC_ALL=C grep -Eq -e "$private_key_re|$encrypted_secret_re" "$path"; then
            report_violation "$path" "private-key marker found"
        fi
    fi
}

for root in "$@"; do
    [ -e "$root" ] || fail "path does not exist: $root"

    if [ -f "$root" ]; then
        check_path_name "$root" || continue
        check_file_content "$root"
        continue
    fi

    [ -d "$root" ] || fail "path is neither a file nor a directory: $root"

    while IFS= read -r -d '' path; do
        check_path_name "$path" || {
            if [ -d "$path" ]; then
                find "$path" -prune >/dev/null
            fi
            continue
        }
        [ -f "$path" ] || continue
        check_file_content "$path"
    done < <(find "$root" \
        \( -name .git -o -name .hg -o -name .svn -o -name target -o -name dist -o -name .venv -o -name node_modules \) -prune \
        -o -print0)
done

[ "$violation_count" -eq 0 ] || exit 1
