#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="PushToTranscribe"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

cd "$PROJECT_DIR"

echo "🔨 Building Push to Transcribe.app..."

echo "🛑 Closing Push to Transcribe if running..."
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

echo "⚙️  Compiling Swift code..."
swift build --configuration release

echo "📦 Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "MacWhisper.app/Contents/Info.plist" "$APP_BUNDLE/Contents/"

cp "Sources/PushToTranscribe/Resources/MacWhisper.entitlements" \
   "$APP_BUNDLE/Contents/Resources/PushToTranscribe.entitlements"

echo "✅ Build complete: $APP_BUNDLE"

echo "📲 Installing to /Applications..."
rm -rf "/Applications/$APP_NAME.app"
cp -r "$APP_BUNDLE" "/Applications/"

echo "🚀 Launching Push to Transcribe..."
sleep 0.5
open "/Applications/$APP_NAME.app"

echo ""
echo "✅ Push to Transcribe is now running!"
echo ""
echo "⚠️  If accessibility permissions stopped working after rebuild:"
echo "   1. Open System Settings → Privacy & Security → Accessibility"
echo "   2. Find 'PushToTranscribe' and REMOVE it (click minus button)"
echo "   3. Click '+' and re-add /Applications/PushToTranscribe.app"
echo "   4. Restart the app"
echo ""
echo "   This is a macOS security feature - when an app's executable changes,"
echo "   you may need to re-grant accessibility permissions."
