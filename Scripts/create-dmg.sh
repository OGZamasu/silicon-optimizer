#!/bin/bash
# Create a DMG from an already signed (and, for public releases, stapled) app bundle.

set -euo pipefail

BUNDLE="${1:-build/Silicon Optimizer.app}"
DMG="${2:-build/Silicon Optimizer.dmg}"
APP_NAME="$(basename "$BUNDLE" .app)"

[[ -d "$BUNDLE" ]] || { echo "ERROR: app bundle is missing: $BUNDLE" >&2; exit 1; }

STAGING="$(mktemp -d)"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT HUP INT TERM

rm -f "$DMG"
# ditto preserves signatures, extended attributes, and the stapled notarization ticket.
ditto "$BUNDLE" "$STAGING/$(basename "$BUNDLE")"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
    -ov -format ULFO "$DMG" >/dev/null
echo "==> Built $DMG"
