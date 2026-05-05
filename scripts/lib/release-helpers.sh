#!/bin/sh

# Shared helpers for release, repository, and smoke scripts.

fail() {
    echo "Error: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_gh_auth() {
    require_command gh
    gh auth status >/dev/null 2>&1 || fail "gh is not authenticated; run 'gh auth login' before using this release helper"
}

capture_or_reexec() {
    output_root="$1"
    slug="$2"
    guard_env="$3"
    label="$4"
    shift 4

    eval "guard_value=\${$guard_env:-}"
    [ "$guard_value" != "1" ] || return 1

    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    run_dir="$output_root/$timestamp-$slug"
    mkdir -p "$run_dir"
    log_file="$run_dir/$timestamp-$slug.txt"
    rc_file="$run_dir/exit-code"
    (
        set +e
        env "$guard_env=1" "$@"
        rc=$?
        printf '%s\n' "$rc" > "$rc_file"
        exit "$rc"
    ) 2>&1 | tee "$log_file"
    rc="$(cat "$rc_file")"
    ln -sfn "$run_dir" "$output_root/latest"
    printf '%s: %s\n' "$label" "$log_file"
    exit "$rc"
}
