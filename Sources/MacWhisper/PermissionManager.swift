import Foundation
import AVFoundation
import Cocoa

class PermissionManager {
    
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
        } else {
            print("❌ Accessibility permission required for global hotkeys")
            print("Requesting accessibility permission...")
            
            // Request accessibility permission
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
            
            if !accessEnabled {
                showAccessibilityPermissionAlert()
            } else {
                print("✅ Accessibility permission granted!")
            }
        }
    }
    
    private func showMicrophonePermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Permission Required"
        alert.informativeText = "Mac Whisper needs access to your microphone to record audio for transcription. Please grant permission in System Preferences > Security & Privacy > Microphone."
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
        alert.informativeText = "Mac Whisper needs accessibility permission to:\n• Monitor global hotkeys (Control + Space)\n• Simulate keystroke events (Cmd + V for pasting)\n\nPlease grant permission in System Preferences > Security & Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            openSystemPreferences(pane: "com.apple.preference.security")
        }
    }
    
    private func openSystemPreferences(pane: String) {
        let url = URL(string: "x-apple.systempreferences:\(pane)?Privacy")!
        NSWorkspace.shared.open(url)
    }
    
    func checkMicrophonePermission() -> Bool {
        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        } else {
            // For older macOS versions, assume permission is granted
            // The system will prompt automatically when we try to use the microphone
            return true
        }
    }
    
    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
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
        
        Both permissions are required for Mac Whisper to function properly.
        """
        alert.alertStyle = .informational
        alert.runModal()
    }
} 