#!/bin/bash
#
# Cuts a release: builds the DMG, signs it for Sparkle, publishes it to GitHub, and updates the
# appcast the app polls.
#
# The EdDSA private key lives in the login keychain — it is never in this repository and never
# passed on a command line. `generate_keys` put it there; `sign_update` reads it back.
#
# Usage: Scripts/release.sh 0.2.0 "What changed in this build"

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: Scripts/release.sh <version> [notes]" >&2
    exit 1
fi

APP_NAME="Silicon Optimizer"
DMG="build/${APP_NAME}.dmg"
FEED="web/public/appcast.xml"
DOWNLOAD_URL="https://github.com/OGZamasu/silicon-optimizer/releases/download/v${VERSION}/Silicon.Optimizer.dmg"

# The build number must increase monotonically — Sparkle compares it, not the marketing
# version, to decide whether an update is newer.
BUILD_NUMBER="$(git rev-list --count HEAD)"

echo "==> Stamping version $VERSION (build $BUILD_NUMBER)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" Resources/Info.plist

echo "==> Building"
# With Vendor/ included: the release ships every runtime the default paths need —
# llama-server for language models and Node.js for the harness chat — so a fresh Mac works
# out of the box, no Homebrew, no terminal. The provenance of each binary is stated in
# THIRD_PARTY_LICENSES.md, which travels inside the bundle. (This reverses an earlier
# policy of stripping Vendor from public builds; issue #11 made the cost of that concrete.)
if [[ ! -x Vendor/llama-server || ! -x Vendor/node ]]; then
    echo "ERROR: Vendor/ is missing llama-server or node — a release must ship both." >&2
    exit 1
fi
./Scripts/build-app.sh --release --dmg

echo "==> Signing the update"
SIGN_TOOL="$(find .build -name sign_update -type f | head -1)"
if [[ -z "$SIGN_TOOL" ]]; then
    echo "sign_update not found — run 'swift build' first" >&2
    exit 1
fi
chmod +x "$SIGN_TOOL"
# sign_update emits BOTH attributes: sparkle:edSignature="..." length="...". Adding our own
# length as well produces a duplicate attribute and an appcast Sparkle cannot parse.
SIGNATURE_LINE="$("$SIGN_TOOL" "$DMG")"

echo "==> Writing the appcast"
PUBDATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
mkdir -p "$(dirname "$FEED")"
cat > "$FEED" <<XML
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Silicon Optimizer</title>
    <link>https://optimize.zamasu.dev/appcast.xml</link>
    <description>Updates for Silicon Optimizer</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${BUILD_NUMBER}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[${NOTES}]]></description>
      <enclosure url="${DOWNLOAD_URL}"
                 type="application/octet-stream"
                 ${SIGNATURE_LINE} />
    </item>
  </channel>
</rss>
XML

echo "==> Publishing to GitHub"
if gh release view "v${VERSION}" >/dev/null 2>&1; then
    gh release upload "v${VERSION}" "$DMG" --clobber
else
    gh release create "v${VERSION}" "$DMG" \
        --title "v${VERSION}" --notes "${NOTES:-See the site for details.}"
fi

echo "==> Deploying the appcast"
(cd web && npx wrangler deploy)

echo
echo "Released ${VERSION} (build ${BUILD_NUMBER})."
echo "Existing installs will see it within a day, or immediately via Check for Updates."
