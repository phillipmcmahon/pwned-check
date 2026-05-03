#!/bin/sh

set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ARTIFACT_DIR="${PWNED_CHECK_RELEASE_ARTIFACT_DIR:-$ROOT/dist/release}"
OUTPUT_DIR="${PWNED_CHECK_RELEASE_PROVENANCE_DIR:-$ARTIFACT_DIR}"
SIGNING_KEY="${PWNED_CHECK_RELEASE_SIGNING_KEY:-}"

usage() {
    cat <<'EOF'
Usage: ./scripts/native-pam-release-provenance.sh

Generate native PAM package checksums and a local provenance manifest for
release-candidate artifacts under dist/release. If
PWNED_CHECK_RELEASE_SIGNING_KEY is set and gpg is available, detached armored
signatures are created for the checksum and provenance files.

Environment:
  PWNED_CHECK_RELEASE_ARTIFACT_DIR     Artifact directory (default: dist/release)
  PWNED_CHECK_RELEASE_PROVENANCE_DIR   Output directory (default: artifact dir)
  PWNED_CHECK_RELEASE_SIGNING_KEY      Optional GPG key id for detach-signing
EOF
}

fail() {
    echo "Error: $*" >&2
    exit 1
}

json_escape() {
    sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "unknown option: $1"

[ -d "$ARTIFACT_DIR" ] || fail "artifact directory not found: $ARTIFACT_DIR"
mkdir -p "$OUTPUT_DIR"

CHECKSUMS="$OUTPUT_DIR/native-pam-SHA256SUMS.txt"
PROVENANCE="$OUTPUT_DIR/native-pam-provenance.json"

find "$ARTIFACT_DIR" -maxdepth 1 -type f \
    -name 'pwned-check-native-pam*' \
    ! -name '*.asc' \
    -print | sort > "$OUTPUT_DIR/native-pam-artifacts.list"

[ -s "$OUTPUT_DIR/native-pam-artifacts.list" ] || fail "no native PAM release artifacts found in $ARTIFACT_DIR"

(
    cd "$ARTIFACT_DIR"
    while IFS= read -r artifact; do
        sha256sum "$(basename "$artifact")"
    done < "$OUTPUT_DIR/native-pam-artifacts.list"
) > "$CHECKSUMS"

commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
tree_state="unknown"
if git -C "$ROOT" diff --quiet --ignore-submodules -- 2>/dev/null && git -C "$ROOT" diff --cached --quiet --ignore-submodules -- 2>/dev/null; then
    tree_state="clean"
else
    tree_state="dirty"
fi
go_version="$(go version 2>/dev/null || printf unavailable)"
rustc_version="$(rustc --version 2>/dev/null || printf unavailable)"
cargo_version="$(cargo --version 2>/dev/null || printf unavailable)"
source_date_epoch="${SOURCE_DATE_EPOCH:-unset}"
generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
    printf '{\n'
    printf '  "schema": "pwned-check-native-pam-provenance-v1",\n'
    printf '  "generated_at": "%s",\n' "$generated_at"
    printf '  "source_commit": "%s",\n' "$commit"
    printf '  "tree_state": "%s",\n' "$tree_state"
    printf '  "source_date_epoch": "%s",\n' "$source_date_epoch"
    printf '  "toolchain": {\n'
    printf '    "go": "%s",\n' "$(printf '%s' "$go_version" | json_escape)"
    printf '    "rustc": "%s",\n' "$(printf '%s' "$rustc_version" | json_escape)"
    printf '    "cargo": "%s"\n' "$(printf '%s' "$cargo_version" | json_escape)"
    printf '  },\n'
    printf '  "artifacts": [\n'
    first=1
    while IFS= read -r artifact; do
        name="$(basename "$artifact")"
        hash="$(sha256sum "$artifact" | awk '{print $1}')"
        size="$(wc -c < "$artifact" | tr -d ' ')"
        if [ "$first" -eq 0 ]; then
            printf ',\n'
        fi
        first=0
        printf '    { "name": "%s", "sha256": "%s", "size": %s }' "$(printf '%s' "$name" | json_escape)" "$hash" "$size"
    done < "$OUTPUT_DIR/native-pam-artifacts.list"
    printf '\n  ]\n'
    printf '}\n'
} > "$PROVENANCE"

if [ -n "$SIGNING_KEY" ]; then
    command -v gpg >/dev/null 2>&1 || fail "PWNED_CHECK_RELEASE_SIGNING_KEY is set but gpg is not available"
    gpg --batch --yes --local-user "$SIGNING_KEY" --armor --detach-sign "$CHECKSUMS"
    gpg --batch --yes --local-user "$SIGNING_KEY" --armor --detach-sign "$PROVENANCE"
fi

printf 'Native PAM release checksums: %s\n' "$CHECKSUMS"
printf 'Native PAM release provenance: %s\n' "$PROVENANCE"
if [ -n "$SIGNING_KEY" ]; then
    printf 'Native PAM release signatures: %s.asc %s.asc\n' "$CHECKSUMS" "$PROVENANCE"
else
    printf 'Native PAM release signatures skipped: PWNED_CHECK_RELEASE_SIGNING_KEY is not set\n'
fi
