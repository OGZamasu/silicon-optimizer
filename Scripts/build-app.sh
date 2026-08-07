#!/bin/bash
#
# Builds Silicon Optimizer.app from the SwiftPM executable.
#
# SwiftPM produces a bare Mach-O binary; macOS needs a bundle directory around it before
# LSUIElement, the app icon, or a code signature mean anything. This assembles that bundle.
#
# Usage:
#   Scripts/build-app.sh [--release] [--sign "Developer ID Application: ..."] [--dmg]

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="debug"
SIGN_IDENTITY=""
MAKE_DMG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIGURATION="release"; shift ;;
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --dmg) MAKE_DMG=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

APP_NAME="Silicon Optimizer"
BUNDLE="build/${APP_NAME}.app"
BUILD_FLAGS=(--configuration "$CONFIGURATION" --arch arm64)

echo "==> Building ($CONFIGURATION)"
swift build "${BUILD_FLAGS[@]}"
BINARY="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)/SiliconOptimizer"

echo "==> Assembling bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

cp "$BINARY" "$BUNDLE/Contents/MacOS/SiliconOptimizer"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# The icon is optional so a fresh clone builds without asset generation.
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
        "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

# A bundled llama-server, when present, is preferred over any Homebrew copy at runtime.
if [[ -x Vendor/llama-server ]]; then
    echo "==> Embedding llama-server"
    RUNTIME_DIR="$BUNDLE/Contents/Resources/bin"
    mkdir -p "$RUNTIME_DIR"
    cp Vendor/llama-server "$RUNTIME_DIR/"
    cp Vendor/*.dylib "$RUNTIME_DIR/" 2>/dev/null || true

    # CMake bakes the build tree's absolute path in as the rpath, so a copied binary keeps
    # loading its libraries from wherever it was compiled. That works on the build machine and
    # nowhere else — the bundle would ship a runtime that dies with "Library not loaded" on a
    # user's Mac. Repoint it at the bundle itself.
    echo "==> Relocating runtime library paths"
    while IFS= read -r stale; do
        install_name_tool -rpath "$stale" "@loader_path" "$RUNTIME_DIR/llama-server" 2>/dev/null \
            || install_name_tool -delete_rpath "$stale" "$RUNTIME_DIR/llama-server" 2>/dev/null || true
    done < <(otool -l "$RUNTIME_DIR/llama-server" \
        | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | grep -v '^@' || true)

    # The libraries reference each other the same way.
    for lib in "$RUNTIME_DIR"/*.dylib; do
        [[ -f "$lib" ]] || continue
        while IFS= read -r stale; do
            install_name_tool -rpath "$stale" "@loader_path" "$lib" 2>/dev/null \
                || install_name_tool -delete_rpath "$stale" "$lib" 2>/dev/null || true
        done < <(otool -l "$lib" \
            | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | grep -v '^@' || true)
    done

    # Re-signing is mandatory after install_name_tool: editing a Mach-O invalidates its
    # signature, and macOS kills unsigned-but-modified binaries on launch.
    codesign --force --sign - "$RUNTIME_DIR"/*.dylib 2>/dev/null || true
    codesign --force --sign - "$RUNTIME_DIR/llama-server"

    # Prove it before shipping: a bundle whose runtime cannot start is worse than one with no
    # runtime at all, because the app will not fall back to Homebrew.
    if ! "$RUNTIME_DIR/llama-server" --version >/dev/null 2>&1; then
        echo "ERROR: embedded llama-server cannot launch after relocation" >&2
        exit 1
    fi
fi

echo "==> Signing"
if [[ -n "$SIGN_IDENTITY" ]]; then
    # Hardened runtime is required for notarization. The JIT entitlement is not needed —
    # inference runs in a child process that is signed separately.
    codesign --force --deep --options runtime --timestamp \
        --entitlements Resources/SiliconOptimizer.entitlements \
        --sign "$SIGN_IDENTITY" "$BUNDLE"
    codesign --verify --strict --verbose=2 "$BUNDLE"
else
    # Ad-hoc signing is enough to run locally; without any signature at all macOS refuses
    # to launch the bundle on Apple Silicon.
    codesign --force --deep --sign - "$BUNDLE"
fi

echo "==> Built $BUNDLE"

if [[ "$MAKE_DMG" == "1" ]]; then
    echo "==> Creating disk image"
    DMG="build/${APP_NAME}.dmg"
    rm -f "$DMG"
    STAGING="$(mktemp -d)"
    cp -R "$BUNDLE" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" \
        -ov -format ULFO "$DMG" >/dev/null
    rm -rf "$STAGING"
    echo "==> Built $DMG"
fi
