#!/bin/bash

echo "🔨 Building Push to Transcribe.app..."

# Close the app if it's running
echo "🛑 Closing Push to Transcribe if running..."
pkill -x "PushToTranscribe" 2>/dev/null
sleep 0.5

# Clean previous builds
rm -rf PushToTranscribe.app/Contents/MacOS/PushToTranscribe

# Build the Swift package
echo "⚙️  Compiling Swift code..."
swift build --configuration release

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# Copy the executable to the app bundle
echo "📦 Creating app bundle..."
cp .build/release/PushToTranscribe PushToTranscribe.app/Contents/MacOS/

# Make the executable... executable
chmod +x PushToTranscribe.app/Contents/MacOS/PushToTranscribe

echo "✅ Build complete!"

# Install to Applications
echo "📲 Installing to /Applications..."
rm -rf /Applications/PushToTranscribe.app
cp -r PushToTranscribe.app /Applications/

echo "✅ Installed to /Applications!"

# Launch the app
echo "🚀 Launching Push to Transcribe..."
sleep 0.5
open /Applications/PushToTranscribe.app

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