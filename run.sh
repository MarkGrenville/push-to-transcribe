#!/bin/bash

echo "Building and running MacWhisper..."

# Build the app bundle
./build_app.sh

if [ $? -eq 0 ]; then
    echo ""
    echo "🚀 Starting MacWhisper..."
    echo "The app will appear in your menu bar with a microphone icon (🎤)"
    echo "Press Control + Space to start recording, release to stop and paste"
    echo "Press Ctrl+C to quit"
    echo ""
    
    # Run the app
    open MacWhisper.app
else
    echo "❌ Build failed!"
    exit 1
fi 