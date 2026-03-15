#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="PushToTranscribe"
DISPLAY_NAME="Push to Transcribe"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
EXPORTS_DIR="$PROJECT_DIR/exports"
DMG_NAME="PushToTranscribe"
VERSION=$(date +"%Y.%m.%d")

cd "$PROJECT_DIR"

echo "═══════════════════════════════════════════════"
echo "  Building $DISPLAY_NAME for distribution"
echo "═══════════════════════════════════════════════"
echo ""

# Step 1: Build
echo "🛑 Closing $DISPLAY_NAME if running..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "⚙️  Compiling Swift code (release)..."
swift build --configuration release

# Step 2: Create app bundle from scratch
echo "📦 Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "MacWhisper.app/Contents/Info.plist" "$APP_BUNDLE/Contents/"

cp "Sources/PushToTranscribe/Resources/MacWhisper.entitlements" \
   "$APP_BUNDLE/Contents/Resources/PushToTranscribe.entitlements"

echo "✅ App bundle created"

# Step 3: Ad-hoc code sign (allows running on other Macs without Gatekeeper issues for local use)
echo "🔏 Ad-hoc signing the app..."
codesign --force --deep --sign - \
    --entitlements "Sources/PushToTranscribe/Resources/MacWhisper.entitlements" \
    "$APP_BUNDLE"
echo "✅ Code signed (ad-hoc)"

# Step 4: Create exports directory
echo "📁 Preparing exports directory..."
mkdir -p "$EXPORTS_DIR"

# Step 5: Create DMG
DMG_PATH="$EXPORTS_DIR/${DMG_NAME}.dmg"
DMG_TEMP="$EXPORTS_DIR/${DMG_NAME}-temp.dmg"
STAGING_DIR="$EXPORTS_DIR/.dmg-staging"

rm -f "$DMG_PATH" "$DMG_TEMP"
rm -rf "$STAGING_DIR"

echo "💿 Creating DMG installer..."

mkdir -p "$STAGING_DIR"
cp -r "$APP_BUNDLE" "$STAGING_DIR/"

ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "$DISPLAY_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDRW \
    "$DMG_TEMP" \
    -quiet

hdiutil convert "$DMG_TEMP" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH" \
    -quiet

rm -f "$DMG_TEMP"
rm -rf "$STAGING_DIR"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo "═══════════════════════════════════════════════"
echo "  ✅ Export complete!"
echo "═══════════════════════════════════════════════"
echo ""
echo "  DMG:  $DMG_PATH"
echo "  Size: $DMG_SIZE"
echo ""
echo "  To install on another Mac:"
echo "    1. Copy the DMG to the other computer"
echo "    2. Double-click to open it"
echo "    3. Drag $DISPLAY_NAME to Applications"
echo "    4. Open the app and enter your OpenAI API key in Settings > API Key"
echo "    5. Grant Microphone and Accessibility permissions when prompted"
echo ""

# Clean up the build artifact
rm -rf "$APP_BUNDLE"
