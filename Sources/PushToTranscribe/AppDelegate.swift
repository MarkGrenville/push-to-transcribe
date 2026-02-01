import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var audioManager: AudioRecordingManager!
    private var hotkeyManager: HotkeyManager!
    private var whisperClient: WhisperClient!
    private var clipboardUtils: ClipboardUtils!
    private var permissionManager: PermissionManager!
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptionMenuItem: NSMenuItem!
    private var lastTranscription: String = ""
    private var settingsManager: SettingsManager!
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let logger = DiagnosticLogger.shared
        logger.info("Push to Transcribe starting up...", category: "App")
        
        setupStatusBarItem()
        setupManagers()
        
        // Hide the app from the dock
        NSApp.setActivationPolicy(.accessory)
        
        logger.success("App initialized successfully", category: "App")
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Use SF Symbol for flat, single-color icon that adapts to light/dark mode
        if let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone") {
            image.isTemplate = true // Makes it adapt to menu bar appearance
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Push to Transcribe - Voice Transcription (Hold Control+Space to record)"
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        lastTranscriptionMenuItem = NSMenuItem(title: "No transcription yet", action: #selector(copyLastTranscription), keyEquivalent: "")
        menu.addItem(lastTranscriptionMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(checkPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Request Permissions", action: #selector(requestPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "About Push to Transcribe", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    private func updateMenuBarIcon(isRecording: Bool) {
        updateMenuBarIcon(isRecording: isRecording, isTranscribing: false)
    }
    
    private func updateMenuBarIcon(isRecording: Bool, isTranscribing: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let symbolName: String
            let tooltip: String
            let status: String
            
            if isRecording {
                symbolName = "mic.fill"  // Filled mic while recording
                tooltip = "Push to Transcribe - Recording... (Release to stop)"
                status = "Recording..."
            } else if isTranscribing {
                symbolName = "waveform"  // Waveform while processing
                tooltip = "Push to Transcribe - Transcribing audio..."
                status = "Transcribing..."
            } else {
                symbolName = "mic"  // Outline mic when ready
                tooltip = "Push to Transcribe - Voice Transcription (Hold Control+Space to record)"
                status = "Ready"
            }
            
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: status) {
                image.isTemplate = true
                self.statusItem.button?.image = image
            }
            self.statusItem.button?.toolTip = tooltip
            self.statusMenuItem.title = status
        }
    }
    
    private func setupManagers() {
        // Initialize settings first
        settingsManager = SettingsManager()
        
        permissionManager = PermissionManager()
        audioManager = AudioRecordingManager()
        whisperClient = WhisperClient(apiKey: "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", settingsManager: settingsManager)
        clipboardUtils = ClipboardUtils()
        
        // Check permissions before setting up hotkeys
        checkPermissionsOnStartup()
        
        hotkeyManager = HotkeyManager(settingsManager: settingsManager)
        
        // Setup hotkey callback
        hotkeyManager.onHotkeyPressed = { [weak self] in
            self?.startRecording()
        }
        
        hotkeyManager.onHotkeyReleased = { [weak self] in
            self?.stopRecording()
        }
        
        // Setup audio recording callback
        audioManager.onAudioDataReceived = { [weak self] audioData in
            // Just accumulate audio while recording, don't process it yet
            self?.whisperClient.accumulateAudio(audioData: audioData)
        }
        
        // Setup callback for when recording fully stops (all buffers captured)
        audioManager.onRecordingStopped = { [weak self] in
            let logger = DiagnosticLogger.shared
            logger.info("Audio capture complete - sending to API", category: "Recording")
            // Only process audio after all buffers have been captured
            self?.whisperClient.processAccumulatedAudio()
        }
        
        // Setup transcription completion callback
        whisperClient.onTranscriptionComplete = { [weak self] finalTranscript in
            let logger = DiagnosticLogger.shared
            logger.debug("onTranscriptionComplete callback fired", category: "Recording")
            self?.handleTranscriptionComplete(finalTranscript)
        }
        
        // Listen for hotkey changes
        settingsManager.hotkeyChanged = { [weak self] in
            self?.hotkeyManager.updateHotkey()
        }
    }
    
    private func checkPermissionsOnStartup() {
        let hasAccessibility = permissionManager.checkAccessibilityPermission()
        let hasMicrophone = permissionManager.checkMicrophonePermission()
        
        if !hasAccessibility || !hasMicrophone {
            // Show a non-intrusive status update
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.statusMenuItem.title = "Permissions needed"
            }
        }
    }
    
    private func startRecording() {
        let logger = DiagnosticLogger.shared
        logger.info("Recording started - hotkey pressed", category: "Recording")
        
        // Store the currently focused app before recording starts
        clipboardUtils.storeCurrentFocusedApp()
        
        updateMenuBarIcon(isRecording: true)
        audioManager.startRecording()
    }
    
    private func stopRecording() {
        let logger = DiagnosticLogger.shared
        logger.info("Recording stopped - hotkey released", category: "Recording")
        
        // Show transcribing state immediately for user feedback
        updateMenuBarIcon(isRecording: false, isTranscribing: true)
        
        // Stop recording - the audio manager will call onRecordingStopped callback
        // when all audio buffers have been captured, which then triggers transcription
        audioManager.stopRecording()
    }
    
    private func addTranscriptionToHistory(_ text: String) {
        // Only add if it's meaningful (not empty and not just whitespace)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty || trimmedText.count < 3 {
            return
        }
        
        // Check if this is a duplicate or just an extension of the most recent entry
        if let mostRecent = settingsManager.transcriptionHistory.first {
            // If the new text is contained in the most recent entry, don't add it
            if mostRecent.text.contains(trimmedText) {
                return
            }
            // If the new text contains the most recent entry, replace it
            if trimmedText.contains(mostRecent.text) {
                settingsManager.transcriptionHistory.removeFirst()
            }
        }
        
        lastTranscription = trimmedText
        updateLastTranscriptionMenuItem()
        settingsManager.addTranscription(trimmedText)
        print("📚 Added to history: \(trimmedText)")
    }
    
    private func showTranscriptionNotification(text: String) {
        let notification = NSUserNotification()
        notification.title = "MacWhisper Transcription"
        notification.informativeText = text.count > 100 ? String(text.prefix(100)) + "..." : text
        notification.soundName = nil // Silent notification
        
        NSUserNotificationCenter.default.deliver(notification)
    }

    func showNotification(title: String, body: String) {
        // Dispatch to background thread to avoid main thread blocking
        DispatchQueue.global(qos: .userInitiated).async {
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = body
            notification.soundName = nil
            
            // Post notification on main thread
            DispatchQueue.main.async {
                NSUserNotificationCenter.default.deliver(notification)
            }
        }
    }
    
    private func handleTranscriptionComplete(_ finalTranscript: String) {
        let logger = DiagnosticLogger.shared
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedTranscript.isEmpty {
            logger.warning("Transcription completed but result is empty", category: "Recording")
        } else {
            logger.success("Transcription completed: \(trimmedTranscript.count) characters", category: "Recording")
        }
        
        // Update UI on main thread
        DispatchQueue.main.async {
            self.updateMenuBarIcon(isRecording: false, isTranscribing: false)
        }
        
        // Add to history
        if !trimmedTranscript.isEmpty {
            settingsManager.addTranscription(trimmedTranscript)
            updateLastTranscriptionMenuItem()
            
            // Check if copy to clipboard is enabled
            if settingsManager.copyToClipboard {
                // Check if auto-paste is enabled
                if settingsManager.autoPaste {
                    // Check accessibility permission before attempting auto-paste
                    if permissionManager.checkAccessibilityPermission() {
                        clipboardUtils.pasteTextAutomatically(text: trimmedTranscript)
                        self.showSimpleNotification(title: "✅ Auto-Pasted", body: trimmedTranscript)
                    } else {
                        // No accessibility permission - just copy to clipboard
                        DispatchQueue.main.async {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(trimmedTranscript, forType: .string)
                            
                            self.showSimpleNotification(title: "📋 Copied to Clipboard", 
                                                      body: "Grant Accessibility permission for auto-paste")
                        }
                    }
                } else {
                    // Just copy to clipboard without auto-pasting
                    DispatchQueue.main.async {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(trimmedTranscript, forType: .string)
                        
                        self.showSimpleNotification(title: "✅ Copied to Clipboard", body: trimmedTranscript)
                    }
                }
            } else {
                // Not copying to clipboard - just show notification
                self.showSimpleNotification(title: "✅ Transcribed", body: trimmedTranscript)
            }
        }
    }
    
    private func showSimpleNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName // Add sound for better UX
        
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Push to Transcribe"
        alert.informativeText = "Real-time voice transcription using OpenAI Whisper API\n\nPress and hold Control + Space to record and transcribe speech."
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc private func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(settingsManager: settingsManager)
            let hostingController = NSHostingController(rootView: settingsView)
            
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            
            settingsWindow?.title = "MacWhisper Settings"
            settingsWindow?.contentViewController = hostingController
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func requestPermissions() {
        permissionManager.requestMicrophonePermission()
        permissionManager.requestAccessibilityPermission()
    }
    
    @objc private func checkPermissions() {
        permissionManager.showPermissionStatus()
    }
    
    @objc private func copyLastTranscription() {
        guard let recent = settingsManager.transcriptionHistory.first else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recent.text, forType: .string)
        
        showSimpleNotification(title: "📋 Copied!", body: "Transcription copied to clipboard")
    }
    

    
    private func updateLastTranscriptionMenuItem() {
        DispatchQueue.main.async {
            if self.settingsManager.transcriptionHistory.isEmpty {
                self.lastTranscriptionMenuItem.title = "Last: (none)"
                self.lastTranscriptionMenuItem.isEnabled = false
            } else {
                let recent = self.settingsManager.transcriptionHistory[0]
                let preview = recent.text.count > 40 ? String(recent.text.prefix(40)) + "..." : recent.text
                self.lastTranscriptionMenuItem.title = "Last: \(preview)"
                self.lastTranscriptionMenuItem.isEnabled = true
            }
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
} 