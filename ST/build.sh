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

# Proper ad-hoc code signing for TCC / Accessibility compliance
echo "==> Signing $APP_BUNDLE..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --force --sign - "$BIN_DIR/$APP_NAME"

echo "==> Successfully built and signed $APP_BUNDLE and $BIN_DIR/$APP_NAME"
