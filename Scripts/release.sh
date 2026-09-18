#!/bin/bash
#
# Cuts a release: Developer ID signs and notarizes the app and DMG, signs the DMG for Sparkle,
# publishes it to GitHub, and updates the appcast the app polls.
#
# The EdDSA private key lives in the login keychain — it is never in this repository and never
# passed on a command line. `generate_keys` put it there; `sign_update` reads it back.
#
# Usage:
#   DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
#   APPLE_NOTARY_PROFILE="silicon-optimizer" \
#   Scripts/release.sh 0.2.0 "What changed in this build"

set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
NOTES="${2:-}"
SIGN_IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
if [[ -z "$VERSION" || -z "$SIGN_IDENTITY" || -z "$NOTARY_PROFILE" ]]; then
    echo "Usage: DEVELOPER_ID_APPLICATION='Developer ID Application: ...' APPLE_NOTARY_PROFILE=profile Scripts/release.sh <version> [notes]" >&2
    exit 1
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "ERROR: version must be a release version such as 1.2.3" >&2
    exit 1
}
[[ "$SIGN_IDENTITY" == "Developer ID Application: "* ]] || {
    echo "ERROR: DEVELOPER_ID_APPLICATION must name a Developer ID Application identity" >&2
    exit 1
}
[[ "$NOTARY_PROFILE" != -* && "$NOTARY_PROFILE" != *$'\n'* && "$NOTARY_PROFILE" != *$'\r'* ]] || {
    echo "ERROR: invalid APPLE_NOTARY_PROFILE" >&2
    exit 1
}

for command in security codesign spctl xcrun ditto hdiutil npm gh git python3 shasum swift; do
    command -v "$command" >/dev/null || { echo "ERROR: required command not found: $command" >&2; exit 1; }
done
security find-identity -v -p codesigning | grep -Fq "\"${SIGN_IDENTITY}\"" || {
    echo "ERROR: requested Developer ID identity is not available in the keychain" >&2
    exit 1
}

APP_NAME="Silicon Optimizer"
DMG="build/${APP_NAME}.dmg"
BUNDLE="build/${APP_NAME}.app"
FEED="web/public/appcast.xml"
DOWNLOAD_URL="https://github.com/OGZamasu/silicon-optimizer/releases/download/v${VERSION}/Silicon.Optimizer.dmg"
MANIFEST="Scripts/vendor-runtime-manifest.sha256"

# Vendor/ itself is ignored, so its allow-list must be committed and unmodified. The same
# holds for the npm dependency declaration and lock consumed by deployment. These checks run
# before version stamping to keep a failed release from dirtying source files.
for locked_input in "$MANIFEST" Package.swift Package.resolved \
    web/package.json web/package-lock.json web/wrangler.jsonc; do
    git cat-file -e "HEAD:${locked_input}" 2>/dev/null || {
        echo "ERROR: ${locked_input} must be committed before releasing" >&2
        exit 1
    }
    git diff --quiet HEAD -- "$locked_input" || {
        echo "ERROR: ${locked_input} has uncommitted changes" >&2
        exit 1
    }
done
./Scripts/verify-vendor-runtime.sh

echo "==> Installing the locked web deployment toolchain"
(
    cd web
    npm ci --ignore-scripts
    [[ -x ./node_modules/.bin/wrangler ]] || {
        echo "ERROR: locked Wrangler binary was not installed" >&2
        exit 1
    }
    [[ "$(./node_modules/.bin/wrangler --version)" == "4.120.0" ]] || {
        echo "ERROR: installed Wrangler does not match the reviewed version" >&2
        exit 1
    }
)

# A fresh SwiftPM scratch tree prevents an ignored, locally replaced dependency checkout or
# sign_update executable from being reused by a public release. SwiftPM validates the pinned
# source revision and Sparkle artifact checksum as it populates this directory.
RELEASE_TMP="$(mktemp -d)"
cleanup() { rm -rf "$RELEASE_TMP"; }
trap cleanup EXIT HUP INT TERM

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
SILICON_SWIFT_SCRATCH_PATH="$RELEASE_TMP/swift-build" \
    ./Scripts/build-app.sh --release --sign "$SIGN_IDENTITY"

echo "==> Verifying the Developer ID signature"
codesign --verify --deep --strict --verbose=2 "$BUNDLE"
codesign -dv --verbose=4 "$BUNDLE" 2>&1 | grep -Fq "Authority=${SIGN_IDENTITY}" || {
    echo "ERROR: built app is not signed with the requested Developer ID identity" >&2
    exit 1
}

notarize() {
    local artifact="$1" label="$2" result status
    echo "==> Notarizing ${label}"
    result="$(xcrun notarytool submit "$artifact" \
        --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)"
    status="$(printf '%s' "$result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))')"
    [[ "$status" == "Accepted" ]] || {
        echo "ERROR: notarization of ${label} finished as ${status:-unknown}" >&2
        printf '%s\n' "$result" >&2
        exit 1
    }
}

# Notarize and staple the app before placing it into the DMG, so offline Gatekeeper can
# validate both the copied app and its distribution container.
NOTARY_ZIP="$RELEASE_TMP/${APP_NAME}.zip"
ditto -c -k --keepParent "$BUNDLE" "$NOTARY_ZIP"
notarize "$NOTARY_ZIP" "app"
xcrun stapler staple "$BUNDLE"
xcrun stapler validate "$BUNDLE"
spctl --assess --type execute --verbose=4 "$BUNDLE"

echo "==> Creating the notarized disk image"
./Scripts/create-dmg.sh "$BUNDLE" "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG" "disk image"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

echo "==> Signing the update"
SIGN_TOOL="$RELEASE_TMP/swift-build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ ! -x "$SIGN_TOOL" ]]; then
    echo "sign_update not found — run 'swift build' first" >&2
    exit 1
fi
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
(cd web && ./node_modules/.bin/wrangler deploy)

echo
echo "Released ${VERSION} (build ${BUILD_NUMBER})."
echo "Existing installs will see it within a day, or immediately via Check for Updates."
