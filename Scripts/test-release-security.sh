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

# The signing checks must survive tools that keep writing after the line they look for:
# `codesign -dv` writes its details line by line to stderr, Authority first, so a check that
# stops reading at the match must not turn the writer's SIGPIPE into a rejection.
IDENTITY="Developer ID Application: Example (TEAMID)"
FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/codesign" <<'SH'
#!/bin/bash
{
    echo "Executable=/Applications/Example.app/Contents/MacOS/Example"
    echo "Authority=${FAKE_AUTHORITY}"
    echo "Authority=Developer ID Certification Authority"
    echo "Authority=Apple Root CA"
    for i in $(seq 1 20000); do echo "Sealed resource entry $i"; done
} >&2
SH
cat > "$FAKE_BIN/security" <<'SH'
#!/bin/bash
echo "  1) 0000000000000000000000000000000000000000 \"${FAKE_AUTHORITY}\""
for i in $(seq 1 20000); do echo "  $((i + 1))) 1111111111111111111111111111111111111111 \"Apple Development: Other $i\""; done
echo "     $((20001)) valid identities found"
SH
chmod +x "$FAKE_BIN/codesign" "$FAKE_BIN/security"
release_check() {
    # Only ever the fakes above: never the real security or codesign.
    (
        PATH="$FAKE_BIN:$PATH"
        [[ "$(command -v security)" == "$FAKE_BIN/security" && "$(command -v codesign)" == "$FAKE_BIN/codesign" ]] || exit 2
        source "$ROOT/Scripts/release.sh"
        "$@"
    )
}
FAKE_AUTHORITY="$IDENTITY" release_check signed_with_identity "$TMP_DIR/Example.app" "$IDENTITY" || {
    echo "a build signed with the requested identity was rejected" >&2; exit 1
}
FAKE_AUTHORITY="$IDENTITY" release_check identity_in_keychain "$IDENTITY" || {
    echo "an identity in the keychain was reported missing" >&2; exit 1
}
if FAKE_AUTHORITY="Developer ID Application: Someone Else (OTHER)" \
    release_check signed_with_identity "$TMP_DIR/Example.app" "$IDENTITY"; then
    echo "a build signed with another identity was accepted" >&2; exit 1
fi
if FAKE_AUTHORITY="$IDENTITY (EXTRA)" release_check signed_with_identity "$TMP_DIR/Example.app" "$IDENTITY"; then
    echo "a build signed with an identity that merely starts with the requested one was accepted" >&2; exit 1
fi
if FAKE_AUTHORITY="Developer ID Application: Someone Else (OTHER)" \
    release_check identity_in_keychain "$IDENTITY"; then
    echo "an identity missing from the keychain was reported available" >&2; exit 1
fi

if env -u DEVELOPER_ID_APPLICATION -u APPLE_NOTARY_PROFILE \
    "$ROOT/Scripts/release.sh" 1.2.3 >/dev/null 2>&1; then
    echo "release accepted missing signing/notarization configuration" >&2
    exit 1
fi

echo "Release security policy checks passed."
