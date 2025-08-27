#!/bin/bash

echo "Building Push to Transcribe.app..."

# Clean previous builds
rm -rf PushToTranscribe.app/Contents/MacOS/PushToTranscribe

# Build the Swift package
echo "Compiling Swift code..."
swift build --configuration release

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# Copy the executable to the app bundle
echo "Creating app bundle..."
cp .build/release/PushToTranscribe PushToTranscribe.app/Contents/MacOS/

# Make the executable... executable
chmod +x PushToTranscribe.app/Contents/MacOS/PushToTranscribe

echo "✅ Push to Transcribe.app created successfully!"
echo ""
echo "📦 Your app is ready at: PushToTranscribe.app"
echo ""
echo "🚀 To install:"
echo "   1. Copy PushToTranscribe.app to your Applications folder"
echo "   2. Open it from Applications or Launchpad"
echo "   3. Grant permissions when prompted"
echo ""
echo "💡 To copy to Applications folder:"
echo "   cp -r \"PushToTranscribe.app\" /Applications/"
echo ""
echo "🔧 To grant permissions manually:"
echo "   System Preferences → Security & Privacy → Privacy"
echo "   - Add Push to Transcribe to Microphone"
echo "   - Add Push to Transcribe to Accessibility" 