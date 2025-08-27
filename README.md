# Push to Transcribe - Real-time Voice Transcription

A macOS menu bar app that provides real-time voice transcription using OpenAI's Whisper API.

## Features

- 🎤 **Customizable Hotkeys**: Choose your own recording shortcut (default: Control + Space)
- 🔊 **Real-time Audio**: Uses AVAudioEngine for high-quality microphone input
- 🤖 **Multiple AI Models**: Choose between Whisper-1 or GPT-4o Audio for transcription
- 📋 **Smart Auto-paste**: Automatically pastes transcribed text with improved timing
- 🔐 **Privacy-focused**: Runs locally as a menu bar app with secure permissions
- ⚡ **Fast & Efficient**: Optimized for real-time processing with chunked audio
- 🔴 **Visual Feedback**: Menu bar icon changes to red circle when recording
- 📊 **Status Display**: Shows current status in menu (Ready/Recording)
- ⚙️ **Settings Interface**: Full settings window for customization
- 📚 **Transcription History**: View, search, and manage all past transcriptions
- 🌍 **Multi-language**: Support for multiple languages or auto-detection
- 🔔 **Smart Notifications**: Optional desktop notifications for transcriptions

## Requirements

- macOS 11.0 or later
- Xcode 13.0 or later
- OpenAI API key with Whisper API access
- Microphone and Accessibility permissions

## Installation

1. **Clone the repository**:

   ```bash
   git clone <your-repo-url>
   cd mac-whisper
   ```

2. **Configure API Key**:

   - Open `Sources/MacWhisper/AppDelegate.swift`
   - Replace the API key in the `setupManagers()` method with your OpenAI API key

3. **Build the App**:

   ```bash
   ./build_app.sh
   ```

4. **Install the App**:

   ```bash
   # Copy to Applications folder
   cp -r MacWhisper.app /Applications/

   # Or just double-click MacWhisper.app to run it directly
   ```

5. **Test Global Hotkeys** (recommended):

   ```bash
   ./test_hotkeys.sh
   ```

6. **Alternative Options**:
   - **Quick run** (builds and launches): `./run.sh`
   - **Manual build**: `swift build && .build/release/MacWhisper`
   - **Xcode project**: `swift package generate-xcodeproj && open MacWhisper.xcodeproj`

## Usage

1. **Launch the app**:

   - Open MacWhisper from Applications or double-click MacWhisper.app
   - The microphone icon (🎤) will appear in your menu bar

2. **Grant permissions**:

   - The app will automatically request permissions when you first try to use it
   - Or click the menu bar icon and select "Request Permissions"
   - Grant microphone access in System Preferences > Security & Privacy > Microphone
   - Grant accessibility access in System Preferences > Security & Privacy > Accessibility

3. **Configure settings** (optional):

   - Click the menu bar icon → "Settings..." or press Cmd+,
   - **General tab**: Choose transcription model and language
   - **Hotkeys tab**: Customize your recording shortcut
   - **History tab**: View and search past transcriptions

4. **Start transcribing**:
   - Press and hold your hotkey (default: `Control + Space`) to start recording
   - The menu bar icon will change to 🔴 (red circle) while recording
   - Speak clearly into your microphone
   - Release the keys to stop recording
   - The icon returns to 🎤 (microphone) when idle
   - The transcribed text will be automatically pasted into the active text field

## Settings Interface

The app includes a comprehensive settings window with three tabs:

### **General Settings** ⚙️

- **Transcription Model**: Choose between Whisper-1 (standard) and GPT-4o Audio (premium)
- **Language**: Auto-detect or force specific languages (English, Spanish, French, etc.)
- **Notifications**: Toggle desktop notifications on/off
- **Auto-paste**: Enable/disable automatic pasting

### **Hotkey Settings** ⌨️

- **Custom Shortcuts**: Set your preferred recording hotkey combination
- **Popular Options**: Quick buttons for Control+Space, Option+Space, Cmd+Shift+R
- **Conflict Detection**: Warnings about potential conflicts with other apps

### **Transcription History** 📚

- **Search & Browse**: View all past transcriptions with search functionality
- **Copy to Clipboard**: Click any transcription to copy it again
- **Export**: Save your transcription history to a text file
- **Auto-cleanup**: Keeps the most recent 100 transcriptions

## How It Works

1. **Audio Recording**: Uses AVAudioEngine to capture real-time audio from the microphone
2. **Hotkey Detection**: Monitors configurable global hotkeys using Carbon API for reliability
3. **Audio Processing**: Properly converts audio using AVAudioConverter from input format (48kHz) to 16kHz mono PCM
4. **Quality Control**: Uses larger buffers (4096 samples) and proper resampling for high-quality audio
5. **AI Transcription**: Sends 1-second audio chunks to your chosen model (Whisper-1 or GPT-4o Transcribe)
6. **Text Accumulation**: Combines transcription results into a final transcript
7. **Smart Auto-paste**: Copies text to clipboard and intelligently pastes with proper timing

## Architecture

- **AppDelegate**: Main app coordinator and menu bar handler
- **AudioRecordingManager**: Handles microphone input using AVAudioEngine
- **HotkeyManager**: Manages global hotkey detection and events
- **WhisperClient**: Handles OpenAI API communication and transcription
- **ClipboardUtils**: Manages clipboard operations and keystroke simulation
- **PermissionManager**: Handles microphone and accessibility permissions

## Configuration

### API Settings

- **Model**: Uses `whisper-1` model
- **Format**: Expects 16kHz mono PCM audio
- **Chunk Size**: 16KB minimum buffer before API calls
- **Response Format**: JSON with transcribed text

### Permissions Required

- **Microphone**: For audio recording
- **Accessibility**: For global hotkey monitoring and keystroke simulation

## Troubleshooting

### Common Issues

1. **Global hotkey (Control + Space) not working**:

   - **MOST IMPORTANT**: Ensure accessibility permissions are granted
   - Go to System Preferences → Security & Privacy → Privacy → Accessibility
   - Add MacWhisper to the list and ensure it's checked ✅
   - **Restart MacWhisper** after granting permissions
   - Check for conflicts with Spotlight (which also uses Control + Space by default)
   - Run `./test_hotkeys.sh` for guided troubleshooting

2. **Spotlight conflict with Control + Space**:

   - Go to System Preferences → Keyboard → Shortcuts → Spotlight
   - Change "Show Spotlight search" to a different shortcut (like Cmd + Space)
   - Or go to System Preferences → Spotlight → Keyboard shortcuts and uncheck the box

3. **No audio recording**:

   - Verify microphone permissions in System Preferences → Security & Privacy → Microphone
   - Ensure MacWhisper is listed and checked ✅
   - Test your microphone in other apps to confirm it's working

4. **API errors**:

   - Verify your OpenAI API key is valid and has Whisper API access
   - Check your API usage and billing status
   - Ensure you have sufficient credits

5. **Paste not working**:

   - Ensure accessibility permissions are granted (same as hotkey issue)
   - The app needs accessibility permission to simulate Cmd + V keystroke

6. **App only works when menu is open**:

   - This indicates missing accessibility permissions
   - Follow the steps in issue #1 above

### Debug Mode

The app includes console logging for debugging:

- Open Console.app
- Search for "MacWhisper" to see debug messages
- Check for audio engine status, API responses, and permission issues

## Security & Privacy

- **Local Processing**: Audio is only sent to OpenAI's secure API endpoint
- **No Storage**: Audio data is not stored locally or persistently
- **Permissions**: Only requests necessary microphone and accessibility permissions
- **Secure API**: Uses HTTPS for all API communications

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## Support

For issues, questions, or feature requests, please:

1. Check the troubleshooting section above
2. Search existing issues
3. Create a new issue with detailed information about your problem

---

**Note**: This app requires an active OpenAI API key with access to the Whisper API. Usage will be billed according to OpenAI's pricing structure.
