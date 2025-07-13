#!/bin/bash

echo "Building MacWhisper.app..."

# Clean previous builds
rm -rf MacWhisper.app/Contents/MacOS/MacWhisper

# Build the Swift package
echo "Compiling Swift code..."
swift build --configuration release

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# Copy the executable to the app bundle
echo "Creating app bundle..."
cp .build/release/MacWhisper MacWhisper.app/Contents/MacOS/

# Make the executable... executable
chmod +x MacWhisper.app/Contents/MacOS/MacWhisper

echo "✅ MacWhisper.app created successfully!"
echo ""
echo "📦 Your app is ready at: MacWhisper.app"
echo ""
echo "🚀 To install:"
echo "   1. Copy MacWhisper.app to your Applications folder"
echo "   2. Open it from Applications or Launchpad"
echo "   3. Grant permissions when prompted"
echo ""
echo "💡 To copy to Applications folder:"
echo "   cp -r MacWhisper.app /Applications/"
echo ""
echo "🔧 To grant permissions manually:"
echo "   System Preferences → Security & Privacy → Privacy"
echo "   - Add MacWhisper to Microphone"
echo "   - Add MacWhisper to Accessibility" 