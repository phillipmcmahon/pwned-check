#!/usr/bin/env bash

set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION=""
INPUT_DIR="$ROOT/dist/release"
HOST="${PWNED_CHECK_NAS_HOST:-homestorage}"
REMOTE_ROOT="${PWNED_CHECK_NAS_RELEASE_ROOT:-/volume1/homes/phillipmcmahon/code/pwned-check}"
REPO="${PWNED_CHECK_GITHUB_REPO:-phillipmcmahon/pwned-check}"
SOURCE="${PWNED_CHECK_NAS_ARCHIVE_SOURCE:-github}"

usage() {
  cat <<'EOF'
Usage: scripts/archive-release-to-nas.sh --version <version> [OPTIONS]

Copy release artifacts to the NAS archive layout:

  <remote-root>/archive/<version>/
  <remote-root>/latest/<version>/

By default the staged artifact set is downloaded from the immutable GitHub
Release assets for the tag. GitHub source archives are downloaded from the same
release tag and named like the GitHub UI: "Source code (tar.gz)" and
"Source code (zip)".

Options:
  --version <version>       Release version, for example v0.1.6 or 0.1.6
  --input-dir <path>        Release artifact directory (default: dist/release)
                             Used only with --source local
  --source <github|local>   Archive source (default: github)
  --repo <owner/name>       GitHub repository (default: phillipmcmahon/pwned-check)
  --host <ssh-host>         SSH host (default: homestorage)
  --remote-root <path>      NAS project root
                             (default: /volume1/homes/phillipmcmahon/code/pwned-check)
  --help                    Show this help text
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
    --input-dir)
      [ "$#" -ge 2 ] || fail "--input-dir requires a value"
      INPUT_DIR="$2"
      shift 2
      ;;
    --source)
      [ "$#" -ge 2 ] || fail "--source requires a value"
      SOURCE="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || fail "--repo requires a value"
      REPO="$2"
      shift 2
      ;;
    --host)
      [ "$#" -ge 2 ] || fail "--host requires a value"
      HOST="$2"
      shift 2
      ;;
    --remote-root)
      [ "$#" -ge 2 ] || fail "--remote-root requires a value"
      REMOTE_ROOT="$2"
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

[ -n "$VERSION" ] || fail "--version is required"
case "$SOURCE" in
  github|local) ;;
  *) fail "--source must be github or local" ;;
esac
if [ "$SOURCE" = "local" ]; then
  [ -d "$INPUT_DIR" ] || fail "input directory does not exist: $INPUT_DIR"
fi

require_command git
require_command scp
require_command ssh
if [ "$SOURCE" = "github" ]; then
  require_command gh
fi

VERSION_NO_V="${VERSION#v}"
VERSION_TAG="v$VERSION_NO_V"
ref="$VERSION_TAG"
if ! git -C "$ROOT" rev-parse -q --verify "$ref^{commit}" >/dev/null; then
  ref="HEAD"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/pwned-check-nas-release.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT INT TERM

stage="$work_dir/$VERSION_TAG"
mkdir -p "$stage"

if [ "$SOURCE" = "github" ]; then
  gh auth status >/dev/null
  gh release view "$VERSION_TAG" --repo "$REPO" >/dev/null
  gh release download "$VERSION_TAG" --repo "$REPO" --dir "$stage" --clobber --pattern '*'
  # Match GitHub's UI labels exactly so the NAS mirror is easy to compare
  # against the immutable release assets, including the spaces and parentheses.
  gh api "repos/$REPO/tarball/$VERSION_TAG" > "$stage/Source code (tar.gz)"
  gh api "repos/$REPO/zipball/$VERSION_TAG" > "$stage/Source code (zip)"
else
  found=0
  while IFS= read -r file; do
    base="$(basename "$file")"
    case "$base" in
      *"$VERSION_TAG"*|*"$VERSION_NO_V"*|native-pam-SHA256SUMS.txt|native-pam-SHA256SUMS.txt.asc|native-pam-provenance.json|native-pam-provenance.json.asc|SHA256SUMS.txt)
        cp "$file" "$stage/$base"
        found=$((found + 1))
        ;;
    esac
  done < <(find "$INPUT_DIR" -maxdepth 1 -type f | sort)

  [ "$found" -gt 0 ] || fail "no release artifacts matching $VERSION_TAG or $VERSION_NO_V found in $INPUT_DIR"

  # Keep local fallback archives named like GitHub's generated source assets.
  git -C "$ROOT" archive --format=tar.gz --prefix="pwned-check-$VERSION_TAG/" -o "$stage/Source code (tar.gz)" "$ref"
  (
    cd "$ROOT"
    git archive --format=zip --prefix="pwned-check-$VERSION_TAG/" -o "$stage/Source code (zip)" "$ref"
  )
fi

remote_archive="$REMOTE_ROOT/archive/$VERSION_TAG"
remote_latest_root="$REMOTE_ROOT/latest"
remote_latest="$remote_latest_root/$VERSION_TAG"

ssh "$HOST" "rm -rf '$remote_archive' '$remote_latest' && mkdir -p '$REMOTE_ROOT/archive' '$remote_latest_root'"
scp -O -r "$stage" "$HOST:$remote_archive"
ssh "$HOST" "rm -rf '$remote_latest_root'/* && mkdir -p '$remote_latest_root' && cp -a '$remote_archive' '$remote_latest'"

printf 'Archived %s release artifacts to %s:%s and %s:%s\n' "$VERSION_TAG" "$HOST" "$remote_archive" "$HOST" "$remote_latest"
