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
        setupStatusBarItem()
        setupManagers()
        
        // Hide the app from the dock
        NSApp.setActivationPolicy(.accessory)
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon(isRecording: false)
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Status: Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        lastTranscriptionMenuItem = NSMenuItem(title: "Last: (none)", action: #selector(copyLastTranscription), keyEquivalent: "")
        lastTranscriptionMenuItem.isEnabled = false
        menu.addItem(lastTranscriptionMenuItem)
        menu.addItem(NSMenuItem.separator())
        
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Mac Whisper", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Request Permissions", action: #selector(requestPermissions), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        
        statusItem.menu = menu
    }
    
    private func updateMenuBarIcon(isRecording: Bool) {
        DispatchQueue.main.async { [weak self] in
            if isRecording {
                self?.statusItem.button?.title = "🔴"
                self?.statusItem.button?.toolTip = "Mac Whisper - Recording... (Release Control+Space to stop)"
                self?.statusMenuItem.title = "Status: 🔴 Recording..."
            } else {
                self?.statusItem.button?.title = "🎤"
                self?.statusItem.button?.toolTip = "Mac Whisper - Voice Transcription (Hold Control+Space to record)"
                self?.statusMenuItem.title = "Status: 🎤 Ready"
            }
        }
    }
    
    private func setupManagers() {
        // Initialize settings first
        settingsManager = SettingsManager()
        
        permissionManager = PermissionManager()
        audioManager = AudioRecordingManager()
        whisperClient = WhisperClient(apiKey: "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", settingsManager: settingsManager)
        clipboardUtils = ClipboardUtils(settingsManager: settingsManager)
        
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
            self?.processAudioData(audioData)
        }
        
        // Listen for hotkey changes
        settingsManager.hotkeyChanged = { [weak self] in
            self?.hotkeyManager.updateHotkey()
        }
    }
    
    private func checkPermissionsOnStartup() {
        print("🔍 Checking permissions...")
        
        let hasAccessibility = permissionManager.checkAccessibilityPermission()
        let hasMicrophone = permissionManager.checkMicrophonePermission()
        
        if hasAccessibility && hasMicrophone {
            print("✅ All permissions granted - global hotkeys should work!")
        } else {
            if !hasAccessibility {
                print("❌ Missing accessibility permission - global hotkeys won't work")
                print("💡 Go to System Preferences → Security & Privacy → Privacy → Accessibility")
                print("   and add MacWhisper to the list")
            }
            if !hasMicrophone {
                print("❌ Missing microphone permission - audio recording won't work")
            }
        }
    }
    
    private func startRecording() {
        print("Starting recording...")
        updateMenuBarIcon(isRecording: true)
        audioManager.startRecording()
    }
    
    private func stopRecording() {
        print("Stopping recording...")
        updateMenuBarIcon(isRecording: false)
        audioManager.stopRecording()
        
        // Finalize transcript and paste
        let finalTranscript = whisperClient.getFinalTranscript()
        if !finalTranscript.isEmpty {
            print("📝 Transcription: \(finalTranscript)")
            
            // Store last transcription and add to history
            lastTranscription = finalTranscript
            updateLastTranscriptionMenuItem()
            settingsManager.addTranscription(finalTranscript)
            
            clipboardUtils.copyToClipboard(text: finalTranscript)
            
            if settingsManager.autoPaste {
                clipboardUtils.simulatePasteKeystroke()
            }
            
            // Show notification with the transcribed text
            if settingsManager.showNotifications {
                showTranscriptionNotification(text: finalTranscript)
            }
        } else {
            print("⚠️ No transcription received")
        }
        
        // Clear transcript for next recording
        whisperClient.clearTranscript()
    }
    
    private func showTranscriptionNotification(text: String) {
        let notification = NSUserNotification()
        notification.title = "MacWhisper Transcription"
        notification.informativeText = text.count > 100 ? String(text.prefix(100)) + "..." : text
        notification.soundName = nil // Silent notification
        
        NSUserNotificationCenter.default.deliver(notification)
    }
    
    private func processAudioData(_ audioData: Data) {
        whisperClient.transcribeAudio(audioData: audioData)
    }
    
    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Mac Whisper"
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
    
    @objc private func copyLastTranscription() {
        if !lastTranscription.isEmpty {
            clipboardUtils.copyToClipboard(text: lastTranscription)
            print("📋 Copied last transcription to clipboard")
        }
    }
    
    private func updateLastTranscriptionMenuItem() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if self.lastTranscription.isEmpty {
                self.lastTranscriptionMenuItem.title = "Last: (none)"
                self.lastTranscriptionMenuItem.isEnabled = false
            } else {
                let preview = self.lastTranscription.count > 30 ? 
                    String(self.lastTranscription.prefix(30)) + "..." : 
                    self.lastTranscription
                self.lastTranscriptionMenuItem.title = "Last: \(preview)"
                self.lastTranscriptionMenuItem.isEnabled = true
            }
        }
    }
    
    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
} 