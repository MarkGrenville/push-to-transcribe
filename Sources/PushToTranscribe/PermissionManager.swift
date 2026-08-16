import Foundation
import AVFoundation
import Cocoa

class PermissionManager {
    private let logger = DiagnosticLogger.shared
    
    func requestMicrophonePermission() {
        // On macOS, we need to use AVAudioApplication
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                print("Microphone permission already granted")
            case .denied:
                print("Microphone permission denied")
                showMicrophonePermissionAlert()
            case .undetermined:
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        if granted {
                            print("Microphone permission granted")
                        } else {
                            print("Microphone permission denied")
                            self.showMicrophonePermissionAlert()
                        }
                    }
                }
            @unknown default:
                print("Unknown microphone permission state")
            }
        } else {
            // For older macOS versions, we can't check permissions programmatically
            // The system will prompt automatically when we try to use the microphone
            print("Microphone permission will be requested automatically on first use")
        }
    }
    
    func requestAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        
        if trusted {
            print("✅ Accessibility permission already granted")
            return
        }
        
        print("❌ Accessibility permission required for global hotkeys and auto-paste")
        print("Requesting accessibility permission...")
        
        // Request accessibility permission with prompt
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if !accessEnabled {
            print("⚠️ User needs to manually grant accessibility permission")
            showAccessibilityPermissionAlert()
        } else {
            print("✅ Accessibility permission granted!")
        }
    }
    
    func forceRequestAccessibilityPermission() {
        // Force show the system permission dialog
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        // Also show our custom alert with instructions
        showAccessibilityPermissionAlert()
    }
    
    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "Push to Transcribe needs access to your microphone to record audio for transcription. Please grant permission in System Preferences > Security & Privacy > Microphone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            openSystemPreferences(pane: "com.apple.preference.security")
        }
    }
    
    private func showAccessibilityPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
        Push to Transcribe needs accessibility permission to:
        • Monitor global hotkeys (Caps Lock or your custom shortcut)
        • Automatically paste transcribed text (Cmd + V simulation)
        • Use Apple Events for text input
        
        🔧 How to grant permission:
        1. Open System Preferences > Security & Privacy > Privacy
        2. Select "Accessibility" from the left sidebar
        3. Click the lock icon and enter your password
        4. Find "Push to Transcribe" in the list and check the box ✅
        5. If Push to Transcribe isn't in the list, click "+" and add it
        
        ⚠️ Important: Restart Push to Transcribe after granting permission!
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            openSystemPreferences(pane: "com.apple.preference.security")
        } else if response == .alertSecondButtonReturn {
            // Try to request permission again
            forceRequestAccessibilityPermission()
        }
    }
    
    private func openSystemPreferences(pane: String) {
        // Try new System Settings first (macOS 13+)
        if #available(macOS 13.0, *) {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            if NSWorkspace.shared.open(url) {
                return
            }
        }
        
        // Fallback to old System Preferences
        let url = URL(string: "x-apple.systempreferences:\(pane)?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    func checkMicrophonePermission() -> Bool {
        var granted = true
        if #available(macOS 14.0, *) {
            granted = AVAudioApplication.shared.recordPermission == .granted
        }
        // For older macOS versions, assume permission is granted
        // The system will prompt automatically when we try to use the microphone
        
        logger.info("Microphone permission check: \(granted ? "✅ Granted" : "❌ Denied")", category: "Permissions")
        return granted
    }
    
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        logger.info("Accessibility permission check: \(trusted ? "✅ Granted" : "❌ Denied")", category: "Permissions")
        
        if !trusted {
            logger.warning("Accessibility permission not granted - hotkeys and auto-paste will not work", category: "Permissions")
            logger.info("Tip: If you recently rebuilt the app, you may need to remove and re-add it in System Settings → Privacy & Security → Accessibility", category: "Permissions")
        }
        
        return trusted
    }
    
    func checkAllPermissions() -> Bool {
        return checkMicrophonePermission() && checkAccessibilityPermission()
    }
    
    func showPermissionStatus() {
        let micPermission = checkMicrophonePermission() ? "✅ Granted" : "❌ Denied"
        let accessibilityPermission = checkAccessibilityPermission() ? "✅ Granted" : "❌ Denied"
        
        let alert = NSAlert()
        alert.messageText = "Permission Status"
        alert.informativeText = """
        Microphone: \(micPermission)
        Accessibility: \(accessibilityPermission)
        
        Both permissions are required for Push to Transcribe to function properly.
        
        💡 Auto-paste functionality specifically requires Accessibility permission.
        """
        alert.alertStyle = .informational
        
        if !checkAccessibilityPermission() {
            alert.addButton(withTitle: "Request Accessibility Permission")
            alert.addButton(withTitle: "OK")
            
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                forceRequestAccessibilityPermission()
            }
        } else {
            alert.runModal()
        }
    }
} 