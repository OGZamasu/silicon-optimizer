#!/bin/bash
# Verify every native runtime that build-app.sh can copy from Vendor/ against the
# repository's committed allow-list. The optional paths exist only for hermetic tests.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="${1:-$ROOT/Vendor}"
MANIFEST="${2:-$ROOT/Scripts/vendor-runtime-manifest.sha256}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "$VENDOR_DIR" ]] || die "vendor runtime directory is missing: $VENDOR_DIR"
[[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || die "vendor manifest is missing or is a symlink: $MANIFEST"

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

EXPECTED="$TMP_DIR/expected"
ACTUAL="$TMP_DIR/actual"
: > "$EXPECTED"

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^([0-9a-f]{64})\ \ (llama-server|node|[^/[:space:]]+\.dylib)$ ]]; then
        die "invalid vendor manifest line: $line"
    fi
    digest="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    grep -Fqx "$name" "$EXPECTED" && die "duplicate vendor manifest entry: $name"
    printf '%s\n' "$name" >> "$EXPECTED"

    artifact="$VENDOR_DIR/$name"
    [[ -f "$artifact" && ! -L "$artifact" ]] || die "manifest artifact is missing, non-regular, or a symlink: $name"
    actual_digest="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    [[ "$actual_digest" == "$digest" ]] || die "SHA-256 mismatch for Vendor/$name"
done < "$MANIFEST"

grep -Fqx llama-server "$EXPECTED" || die "manifest does not declare required artifact: llama-server"
grep -Fqx node "$EXPECTED" || die "manifest does not declare required artifact: node"
[[ -x "$VENDOR_DIR/llama-server" ]] || die "Vendor/llama-server is not executable"
[[ -x "$VENDOR_DIR/node" ]] || die "Vendor/node is not executable"

# This is exactly the set build-app.sh is allowed to copy. Unknown documentation and
# licence files are ignored; an undeclared native runtime, including a symlink, is fatal.
find "$VENDOR_DIR" -maxdepth 1 \( -type f -o -type l \) \
    \( -name llama-server -o -name node -o -name '*.dylib' \) \
    -exec basename {} \; | LC_ALL=C sort > "$ACTUAL"
LC_ALL=C sort -o "$EXPECTED" "$EXPECTED"

if ! cmp -s "$EXPECTED" "$ACTUAL"; then
    echo "ERROR: Vendor native runtime set does not match the manifest" >&2
    diff -u "$EXPECTED" "$ACTUAL" >&2 || true
    exit 1
fi

echo "Verified $(wc -l < "$EXPECTED" | tr -d ' ') vendor runtime artifacts."
