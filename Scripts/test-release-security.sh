#!/bin/bash
# Hermetic regression checks for the release supply-chain policy.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT HUP INT TERM

VENDOR="$TMP_DIR/Vendor"
MANIFEST="$TMP_DIR/manifest.sha256"
mkdir -p "$VENDOR"
printf '#!/bin/sh\nexit 0\n' > "$VENDOR/llama-server"
printf '#!/bin/sh\nexit 0\n' > "$VENDOR/node"
printf 'fixture dylib\n' > "$VENDOR/libfixture.dylib"
chmod +x "$VENDOR/llama-server" "$VENDOR/node"

manifest_line() {
    printf '%s  %s\n' "$(shasum -a 256 "$VENDOR/$1" | awk '{print $1}')" "$1"
}
{
    manifest_line llama-server
    manifest_line node
    manifest_line libfixture.dylib
} > "$MANIFEST"

"$ROOT/Scripts/verify-vendor-runtime.sh" "$VENDOR" "$MANIFEST" >/dev/null

printf 'tampered\n' >> "$VENDOR/node"
if "$ROOT/Scripts/verify-vendor-runtime.sh" "$VENDOR" "$MANIFEST" >/dev/null 2>&1; then
    echo "tampered runtime was accepted" >&2
    exit 1
fi
printf '#!/bin/sh\nexit 0\n' > "$VENDOR/node"
chmod +x "$VENDOR/node"

printf 'undeclared\n' > "$VENDOR/libextra.dylib"
if "$ROOT/Scripts/verify-vendor-runtime.sh" "$VENDOR" "$MANIFEST" >/dev/null 2>&1; then
    echo "undeclared runtime was accepted" >&2
    exit 1
fi
rm "$VENDOR/libextra.dylib"

mv "$VENDOR/node" "$VENDOR/node.real"
ln -s node.real "$VENDOR/node"
if "$ROOT/Scripts/verify-vendor-runtime.sh" "$VENDOR" "$MANIFEST" >/dev/null 2>&1; then
    echo "symlinked runtime was accepted" >&2
    exit 1
fi
rm "$VENDOR/node"
mv "$VENDOR/node.real" "$VENDOR/node"

rm "$VENDOR/llama-server"
if "$ROOT/Scripts/verify-vendor-runtime.sh" "$VENDOR" "$MANIFEST" >/dev/null 2>&1; then
    echo "missing runtime was accepted" >&2
    exit 1
fi

grep -Fq 'actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683' "$ROOT/.github/workflows/ci.yml"
if grep -Eq 'actions/checkout@v[0-9]+' "$ROOT/.github/workflows/ci.yml"; then
    echo "mutable checkout action reference found" >&2; exit 1
fi
if grep -E '(^|[[:space:]])npx[[:space:]]+wrangler' "$ROOT/Scripts/release.sh" "$ROOT/web/package.json"; then
    echo "npx Wrangler fallback found" >&2; exit 1
fi
if grep -F 'xattr -d com.apple.quarantine' "$ROOT/web/public/index.html" "$ROOT/Casks/silicon-optimizer.rb"; then
    echo "quarantine bypass instruction found" >&2; exit 1
fi
grep -Fq '"wrangler": "4.120.0"' "$ROOT/web/package.json"
grep -Fq 'npm ci --ignore-scripts' "$ROOT/Scripts/release.sh"
grep -Fq './node_modules/.bin/wrangler deploy' "$ROOT/Scripts/release.sh"

if env -u DEVELOPER_ID_APPLICATION -u APPLE_NOTARY_PROFILE \
    "$ROOT/Scripts/release.sh" 1.2.3 >/dev/null 2>&1; then
    echo "release accepted missing signing/notarization configuration" >&2
    exit 1
fi

echo "Release security policy checks passed."
