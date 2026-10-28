#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="ST"
BUILD_DIR="$SCRIPT_DIR/build"
BIN_DIR="$SCRIPT_DIR/bin"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

echo "==> Building $APP_NAME..."
mkdir -p "$BUILD_DIR" "$BIN_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

# Source files
SOURCES=(
    "Sources/Logger.swift"
    "Sources/OllamaService.swift"
    "Sources/TextExtractor.swift"
    "Sources/SelectionMonitor.swift"
    "Sources/TranslationView.swift"
    "Sources/TranslationPanel.swift"
    "Sources/AppDelegate.swift"
    "Sources/main.swift"
)

# Compile using swiftc
swiftc -O \
    -target arm64-apple-macosx13.0 \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ApplicationServices \
    "${SOURCES[@]}" \
    -o "$MACOS_DIR/$APP_NAME"

# Copy binary to bin/ST for direct CLI usage
cp "$MACOS_DIR/$APP_NAME" "$BIN_DIR/$APP_NAME"

# Copy Info.plist
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Code signing: detect persistent developer identity (e.g. ST-Developer) to prevent TCC permission invalidation across rebuilds
SIGN_IDENTITY="-"
if security find-identity -p codesigning -v 2>/dev/null | grep -q '"ST-Developer"'; then
    SIGN_IDENTITY="ST-Developer"
    echo "==> Signing with persistent identity: $SIGN_IDENTITY (TCC permissions will persist across builds)"
elif security find-identity -p codesigning -v 2>/dev/null | grep -E -q 'Apple Development|Developer ID Application'; then
    FIRST_VALID=$(security find-identity -p codesigning -v | grep -E 'Apple Development|Developer ID Application' | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
    SIGN_IDENTITY="$FIRST_VALID"
    echo "==> Signing with discovered identity: $SIGN_IDENTITY"
else
    echo "==> Signing with ad-hoc identity (-) [Tip: Create an 'ST-Developer' certificate in Keychain Access to retain permissions across rebuilds]"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --force --sign "$SIGN_IDENTITY" "$BIN_DIR/$APP_NAME"

echo "==> Successfully built and signed $APP_BUNDLE and $BIN_DIR/$APP_NAME"
