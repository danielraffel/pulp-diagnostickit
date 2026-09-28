#!/bin/bash

# Build DiagnosticKit App
# This script builds the SwiftUI diagnostic app using Swift Package Manager

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Find DiagnosticKit directory
DIAGNOSTIC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIAGNOSTIC_DIR"

# Build configuration
BUILD_CONFIG="${1:-release}"
BUILD_CONFIG_SWIFT=$(echo "$BUILD_CONFIG" | tr '[:upper:]' '[:lower:]' | sed 's/prod/release/')

echo -e "${GREEN}Building DiagnosticKit...${NC}"
echo "Configuration: $BUILD_CONFIG_SWIFT"

# Check if .env exists
if [[ ! -f ".env" ]]; then
    echo -e "${RED}Error: .env file not found${NC}"
    echo "Run this from the main build.sh which generates the .env file"
    exit 1
fi

# Load configuration
set -a
source .env
set +a

# Create build directory
BUILD_DIR="$DIAGNOSTIC_DIR/build"
mkdir -p "$BUILD_DIR"

APP_NAME="${APP_NAME:-DiagnosticKit}"
APP_BUNDLE_NAME="${APP_NAME}.app"

echo ""
echo "Building Swift package..."

# Build with Swift Package Manager
swift build \
    --configuration "$BUILD_CONFIG_SWIFT" \
    --product DiagnosticKit \
    --build-path "$BUILD_DIR/.build"

if [[ $? -ne 0 ]]; then
    echo -e "${RED}Swift build failed${NC}"
    exit 1
fi

# Get built binary path
if [[ "$BUILD_CONFIG_SWIFT" == "debug" ]]; then
    BINARY_PATH="$BUILD_DIR/.build/debug/DiagnosticKit"
else
    BINARY_PATH="$BUILD_DIR/.build/release/DiagnosticKit"
fi

echo ""
echo "Creating application bundle..."

# Create app bundle structure
APP_PATH="$BUILD_DIR/$APP_BUNDLE_NAME"
rm -rf "$APP_PATH"

mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/$APP_NAME"
chmod +x "$APP_PATH/Contents/MacOS/$APP_NAME"

# SwiftPM records absolute LC_RPATHs into the build machine's toolchain
# (/usr/lib/swift and the Xcode swift-X.Y/macosx directory). The app links no
# @rpath library -- the Swift runtime and frameworks resolve by absolute OS
# paths -- so these entries only point at this machine, and an installer's
# relocatability check rightly rejects them. Refuse to ship if a real @rpath
# dependency ever appears, rather than stripping something it needs.
if otool -L "$APP_PATH/Contents/MacOS/$APP_NAME" | tail -n +2 | grep -q "@rpath/"; then
    echo -e "${RED}Error: the binary links an @rpath library; its rpaths cannot be stripped${NC}"
    exit 1
fi
otool -l "$APP_PATH/Contents/MacOS/$APP_NAME" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | while read -r rpath; do
    install_name_tool -delete_rpath "$rpath" "$APP_PATH/Contents/MacOS/$APP_NAME"
done

# Copy .env into Resources
cp ".env" "$APP_PATH/Contents/Resources/"

# The intake's upload key never lives in a committed .env: when
# DIAGNOSTICKIT_SEND_KEY (and optionally DIAGNOSTICKIT_SEND_ENDPOINT) is set in
# the build environment, it is written into the BUNDLE's copy only.
set_bundle_env() {
    local key="$1" value="$2" file="$APP_PATH/Contents/Resources/.env"
    grep -v "^${key}=" "$file" > "$file.tmp" || true
    printf '%s="%s"\n' "$key" "$value" >> "$file.tmp"
    mv "$file.tmp" "$file"
}
if [[ -n "${DIAGNOSTICKIT_SEND_ENDPOINT:-}" ]]; then set_bundle_env SEND_ENDPOINT "$DIAGNOSTICKIT_SEND_ENDPOINT"; fi
if [[ -n "${DIAGNOSTICKIT_SEND_KEY:-}" ]]; then set_bundle_env SEND_KEY "$DIAGNOSTICKIT_SEND_KEY"; fi

# Diagnostic data terms shown before sending: DiagnosticKit's default
# Resources/TERMS.md, or the product's own via TERMS_FILE in .env.
TERMS_SRC="${TERMS_FILE:-Resources/TERMS.md}"
[[ "$TERMS_SRC" = /* ]] || TERMS_SRC="$DIAGNOSTIC_DIR/$TERMS_SRC"
if [[ -f "$TERMS_SRC" ]]; then
    cp "$TERMS_SRC" "$APP_PATH/Contents/Resources/TERMS.md"
else
    echo -e "${YELLOW}Warning: no terms at $TERMS_SRC; the terms link will say so${NC}"
fi

# App icon: Resources/AppIcon.png (1024x1024, transparent corners) by default;
# a product sets APP_ICON_PNG in .env to use its own. Relative paths resolve
# from this checkout.
ICON_PNG="${APP_ICON_PNG:-Resources/AppIcon.png}"
[[ "$ICON_PNG" = /* ]] || ICON_PNG="$DIAGNOSTIC_DIR/$ICON_PNG"
if [[ -f "$ICON_PNG" ]]; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
else
    echo -e "${YELLOW}Warning: no app icon at $ICON_PNG; the app will use the generic icon${NC}"
fi

# Create Info.plist
cat > "$APP_PATH/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${APP_IDENTIFIER}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © $(date +%Y)</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# NOTE: entitlements are NOT copied into the bundle. Placing a
# DiagnosticKit.entitlements file under Contents/ breaks `codesign` (it tries
# to treat it as a resource). Entitlements are applied at signing time via
# `codesign --entitlements`, not by bundling the plist.

echo -e "${GREEN}✅ Build complete${NC}"
echo "App bundle: $APP_PATH"
echo ""

# Validate app bundle
if [[ -d "$APP_PATH" ]] && [[ -x "$APP_PATH/Contents/MacOS/$APP_NAME" ]]; then
    echo -e "${GREEN}✅ App bundle is valid${NC}"
else
    echo -e "${RED}❌ App bundle validation failed${NC}"
    exit 1
fi

# Export path for build.sh
echo "$APP_PATH"
