import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var audioManager: AudioRecordingManager!
    private var hotkeyManager: HotkeyManager!
    private var whisperClient: WhisperClient!
    private var llmClient: LLMClient!
    private var clipboardUtils: ClipboardUtils!
    private var permissionManager: PermissionManager!
    private var statusMenuItem: NSMenuItem!
    private var lastTranscriptionMenuItem: NSMenuItem!
    private var lastTranscription: String = ""
    private var settingsManager: SettingsManager!
    private var settingsWindow: NSWindow?
    private var errorMenuItem: NSMenuItem!
    private var billingMenuItem: NSMenuItem!
    private var retryMenuItem: NSMenuItem!
    private var errorSeparator: NSMenuItem!
    private var isInErrorState = false
    private static let billingURL = "https://platform.openai.com/settings/organization/billing/overview"
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let logger = DiagnosticLogger.shared
        logger.info("Push to Transcribe starting up...", category: "App")
        
        setupStatusBarItem()
        setupManagers()
        
        // Hide the app from the dock
        NSApp.setActivationPolicy(.accessory)
        
        logger.success("App initialized successfully", category: "App")
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.restoreSystemCapsLock()
    }
    
    private func setupStatusBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        // Use SF Symbol for flat, single-color icon that adapts to light/dark mode
        if let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Microphone") {
            image.isTemplate = true // Makes it adapt to menu bar appearance
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Push to Transcribe - Voice Transcription (Hold Caps Lock to record)"
        
        let menu = NSMenu()
        
        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        
        // Error items (hidden by default, shown on API errors)
        errorSeparator = NSMenuItem.separator()
        errorSeparator.isHidden = true
        menu.addItem(errorSeparator)
        
        errorMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorMenuItem.isEnabled = false
        errorMenuItem.isHidden = true
        menu.addItem(errorMenuItem)
        
        retryMenuItem = NSMenuItem(title: "Retry Transcription", action: #selector(retryTranscription), keyEquivalent: "r")
        retryMenuItem.isHidden = true
        menu.addItem(retryMenuItem)

        billingMenuItem = NSMenuItem(title: "Top Up OpenAI Credits...", action: #selector(openBilling), keyEquivalent: "")
        billingMenuItem.isHidden = true
        menu.addItem(billingMenuItem)
        
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
    
    private enum AppStatus {
        case ready
        case recording
        case uploading(Double)
        case waitingForNetwork
        case transcribing
        case retrying(Int, Int)
        case cleaningUp
        case apiError(String)
    }
    
    private func updateStatus(_ status: AppStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let symbolName: String
            let tooltip: String
            let statusText: String
            var useRedIcon = false
            
            switch status {
            case .recording:
                symbolName = "mic.fill"
                tooltip = "Push to Transcribe - Recording... (Release to stop)"
                statusText = "Recording..."
            case .uploading(let fraction):
                symbolName = "waveform"
                let percent = Int(fraction * 100)
                // On a slow uplink this is where the wait actually is, so show
                // it rather than a spinner that looks identical to a hang.
                statusText = percent >= 99 ? "Transcribing..." : "Uploading... \(percent)%"
                tooltip = "Push to Transcribe - \(statusText)"
            case .waitingForNetwork:
                symbolName = "wifi.exclamationmark"
                statusText = "Waiting for network..."
                tooltip = "Push to Transcribe - waiting for a connection, your audio is safe"
            case .retrying(let attempt, let total):
                symbolName = "arrow.clockwise"
                statusText = "Retrying (\(attempt)/\(total))..."
                tooltip = "Push to Transcribe - \(statusText)"
            case .transcribing:
                symbolName = "waveform"
                tooltip = "Push to Transcribe - Transcribing audio..."
                statusText = "Transcribing..."
            case .cleaningUp:
                symbolName = "sparkles"
                tooltip = "Push to Transcribe - Cleaning up with AI..."
                statusText = "Cleaning up..."
            case .apiError(let message):
                symbolName = "exclamationmark.triangle.fill"
                let short = message.count > 60 ? String(message.prefix(60)) + "..." : message
                tooltip = "Push to Transcribe - API Error: \(short)"
                statusText = "API Error"
                useRedIcon = true
            case .ready:
                symbolName = "mic"
                let hotkey = self.settingsManager?.getHotkeyDescription() ?? "Caps Lock"
                tooltip = "Push to Transcribe - Voice Transcription (Hold \(hotkey) to record)"
                statusText = "Ready"
            }
            
            if useRedIcon {
                if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: statusText) {
                    if #available(macOS 12.0, *) {
                        let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                        if let colored = image.withSymbolConfiguration(config) {
                            colored.isTemplate = false
                            self.statusItem.button?.image = colored
                        } else {
                            image.isTemplate = false
                            self.statusItem.button?.image = image
                        }
                    } else {
                        image.isTemplate = false
                        self.statusItem.button?.image = image
                    }
                }
            } else {
                if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: statusText) {
                    image.isTemplate = true
                    self.statusItem.button?.image = image
                }
            }
            
            self.statusItem.button?.toolTip = tooltip
            self.statusMenuItem.title = statusText
        }
    }
    
    private func setupManagers() {
        settingsManager = SettingsManager()
        
        permissionManager = PermissionManager()
        audioManager = AudioRecordingManager()
        let apiKey = settingsManager.apiKey
        whisperClient = WhisperClient(apiKey: apiKey, settingsManager: settingsManager)
        llmClient = LLMClient(apiKey: apiKey)
        clipboardUtils = ClipboardUtils()
        
        settingsManager.apiKeyChanged = { [weak self] in
            guard let self = self else { return }
            let newKey = self.settingsManager.apiKey
            self.whisperClient.updateAPIKey(newKey)
            self.llmClient.updateAPIKey(newKey)
        }
        
        // Check permissions before setting up hotkeys
        checkPermissionsOnStartup()
        
        hotkeyManager = HotkeyManager(settingsManager: settingsManager)
        
        // Setup hotkey callbacks - now with HotkeyType parameter
        hotkeyManager.onHotkeyPressed = { [weak self] hotkeyType in
            self?.startRecording(mode: hotkeyType)
        }
        
        hotkeyManager.onHotkeyReleased = { [weak self] hotkeyType in
            self?.stopRecording(mode: hotkeyType)
        }
        
        audioManager.onRecordingFinished = { [weak self] clip, mode in
            self?.whisperClient.transcribe(clip, mode: mode)
        }
        
        audioManager.onRecordingTruncated = { [weak self] in
            self?.showSimpleNotification(title: "Recording Stopped",
                                         body: "Hit the 5 minute limit. Transcribing what was captured.")
        }
        
        whisperClient.onTranscriptionComplete = { [weak self] transcript, job in
            self?.handleTranscriptionComplete(transcript, job: job)
        }
        
        whisperClient.onAPIError = { [weak self] failure, job in
            self?.handleAPIError(failure, job: job)
        }
        
        whisperClient.onProgress = { [weak self] progress in
            switch progress {
            case .uploading(let fraction): self?.updateStatus(.uploading(fraction))
            case .waitingForNetwork: self?.updateStatus(.waitingForNetwork)
            case .processing: self?.updateStatus(.transcribing)
            case .retrying(let attempt, let total): self?.updateStatus(.retrying(attempt, total))
            }
        }
        
        // Builds the audio pipeline without opening the microphone, so the
        // device is ready to start the instant a key goes down.
        audioManager.prepare()
        if CommandLine.arguments.contains("--mic-selftest") {
            audioManager.runSelfTest()
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
    
    private func startRecording(mode: HotkeyType) {
        let logger = DiagnosticLogger.shared
        let modeStr = mode == .cleanup ? "cleanup" : "normal"
        logger.info("Recording started - \(modeStr) mode", category: "Recording")
        
        // Store the currently focused app before recording starts
        clipboardUtils.storeCurrentFocusedApp()
        
        updateStatus(.recording)
        audioManager.startRecording(mode: mode)
        
        // Open the TLS connection while the user is still talking so the upload
        // does not start with a handshake.
        whisperClient.warmUpConnection()
    }
    
    private func stopRecording(mode: HotkeyType) {
        let logger = DiagnosticLogger.shared
        let modeStr = mode == .cleanup ? "cleanup" : "normal"
        logger.info("Recording stopped - \(modeStr) mode", category: "Recording")
        
        // Show transcribing state immediately for user feedback
        updateStatus(.transcribing)
        
        // The audio manager gathers the tail of the recording and calls back.
        audioManager.stopRecording()
    }
    
    private func handleAPIError(_ failure: TranscriptionFailure, job: TranscriptionJob?) {
        DiagnosticLogger.shared.error("API error surfaced to user: \(failure.message)", category: "App")
        showAPIError(failure, job: job)
        
        // The recording itself is still held in memory whenever a retry could
        // work, so say so — a failure used to be a dead end that silently threw
        // the audio away.
        let canRetry = whisperClient.pendingRetry != nil
        let title: String
        let body: String
        if failure.isBillingRelated {
            title = "OpenAI Credits Exhausted"
            body = "Your API credits have run out. Top up to continue transcribing."
        } else if canRetry {
            title = "Transcription Failed"
            body = "\(failure.message). Your recording was kept — click the menu bar icon to retry."
        } else {
            title = "Transcription Failed"
            body = failure.message
        }
        
        showSimpleNotification(title: title, body: body)
    }
    
    private func showAPIError(_ failure: TranscriptionFailure, job: TranscriptionJob?) {
        isInErrorState = true
        
        let displayMessage = failure.isBillingRelated
            ? "OpenAI credits exhausted"
            : (failure.message.count > 50 ? String(failure.message.prefix(50)) + "..." : failure.message)
        
        updateStatus(.apiError(displayMessage))
        
        let errorAttr = NSMutableAttributedString(string: displayMessage)
        errorAttr.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: errorAttr.length))
        errorMenuItem.attributedTitle = errorAttr
        errorMenuItem.isHidden = false
        errorSeparator.isHidden = false
        
        billingMenuItem.isHidden = !failure.isBillingRelated
        updateRetryMenuItem()
    }
    
    /// The retry item tracks the parked recording, not the error banner: a
    /// later success clears the banner but the older recording is still there
    /// to be recovered.
    private func updateRetryMenuItem() {
        if let job = whisperClient.pendingRetry {
            retryMenuItem.title = "Retry Failed Transcription (\(Int(job.duration.rounded()))s)"
            retryMenuItem.isHidden = false
        } else {
            retryMenuItem.isHidden = true
        }
        errorSeparator.isHidden = errorMenuItem.isHidden && retryMenuItem.isHidden
    }
    
    private func clearAPIError() {
        guard isInErrorState else { return }
        isInErrorState = false
        errorMenuItem.isHidden = true
        billingMenuItem.isHidden = true
        updateRetryMenuItem()
    }
    
    @objc private func retryTranscription() {
        guard whisperClient.pendingRetry != nil else { return }
        retryMenuItem.isHidden = true
        clearAPIError()
        updateStatus(.transcribing)
        whisperClient.retryPending()
    }
    
    @objc private func openBilling() {
        if let url = URL(string: AppDelegate.billingURL) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func handleTranscriptionComplete(_ finalTranscript: String, job: TranscriptionJob?) {
        let logger = DiagnosticLogger.shared
        let trimmedTranscript = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if trimmedTranscript.isEmpty {
            logger.warning("Transcription completed but result is empty", category: "Recording")
            if !isInErrorState {
                updateStatus(.ready)
            }
            return
        }
        
        // Successful transcription clears any previous error state. The retry
        // item is refreshed unconditionally — clearAPIError is a no-op when no
        // banner is showing, but a retry may still have just been consumed.
        clearAPIError()
        updateRetryMenuItem()
        
        logger.success("Transcription completed: \(trimmedTranscript.count) characters", category: "Recording")
        
        // Archive the raw transcription (before any AI cleanup)
        if let job = job {
            settingsManager.saveTranscriptionToArchive(text: trimmedTranscript, sessionId: job.sessionId)
        }
        
        // Run cleanup if the recording was started with the cleanup hotkey. The
        // mode travels with the job so a retry minutes later still does the
        // right thing.
        if job?.mode == .cleanup {
            logger.info("Cleanup mode - sending to LLM for cleanup", category: "Recording")
            
            updateStatus(.cleaningUp)
            
            let prompt = settingsManager.cleanupPrompt
            let model = settingsManager.cleanupModel
            
            llmClient.cleanupText(trimmedTranscript, prompt: prompt, model: model) { [weak self] cleanedText in
                guard let self = self else { return }
                logger.success("Cleanup completed: \(cleanedText.count) characters", category: "Recording")
                self.finalizeTranscription(cleanedText, wasCleanedUp: true)
            }
        } else {
            // Normal mode - proceed directly to paste
            finalizeTranscription(trimmedTranscript, wasCleanedUp: false)
        }
    }
    
    private func finalizeTranscription(_ text: String, wasCleanedUp: Bool) {
        updateStatus(.ready)
        
        // Add to history
        settingsManager.addTranscription(text)
        updateLastTranscriptionMenuItem()
        
        let notificationPrefix = wasCleanedUp ? "✨" : "✅"
        let notificationTitle = wasCleanedUp ? "\(notificationPrefix) Cleaned & Pasted" : "\(notificationPrefix) Auto-Pasted"
        
        // Check if copy to clipboard is enabled
        if settingsManager.copyToClipboard {
            // Check if auto-paste is enabled
            if settingsManager.autoPaste {
                // Check accessibility permission before attempting auto-paste
                if permissionManager.checkAccessibilityPermission() {
                    clipboardUtils.pasteTextAutomatically(text: text)
                    self.showSimpleNotification(title: notificationTitle, body: text)
                } else {
                    // No accessibility permission - just copy to clipboard
                    DispatchQueue.main.async {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        
                        self.showSimpleNotification(title: "📋 Copied to Clipboard", 
                                                  body: "Grant Accessibility permission for auto-paste")
                    }
                }
            } else {
                // Just copy to clipboard without auto-pasting
                DispatchQueue.main.async {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                    
                    let title = wasCleanedUp ? "✨ Cleaned & Copied" : "✅ Copied to Clipboard"
                    self.showSimpleNotification(title: title, body: text)
                }
            }
        } else {
            // Not copying to clipboard - just show notification
            let title = wasCleanedUp ? "✨ Cleaned" : "✅ Transcribed"
            self.showSimpleNotification(title: title, body: text)
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
        let hotkey = settingsManager.getHotkeyDescription()
        alert.informativeText = "Real-time voice transcription using OpenAI Whisper API\n\nPress and hold \(hotkey) to record and transcribe speech."
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc private func showSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(
                settingsManager: settingsManager,
                onCleanupText: { [weak self] text, completion in
                    self?.cleanupTextFromHistory(text, completion: completion)
                }
            )
            let hostingController = NSHostingController(rootView: settingsView)
            
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            
            settingsWindow?.title = "Push to Transcribe Settings"
            settingsWindow?.contentViewController = hostingController
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }
        
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    private func cleanupTextFromHistory(_ text: String, completion: @escaping (String) -> Void) {
        let logger = DiagnosticLogger.shared
        logger.info("Cleaning up text from history", category: "LLM")
        
        let prompt = settingsManager.cleanupPrompt
        let model = settingsManager.cleanupModel
        
        llmClient.cleanupText(text, prompt: prompt, model: model) { cleanedText in
            logger.success("History cleanup completed: \(cleanedText.count) characters", category: "LLM")
            completion(cleanedText)
        }
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