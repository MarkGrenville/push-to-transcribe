import Foundation
import Cocoa
import CoreGraphics

class ClipboardUtils {
    private weak var settingsManager: SettingsManager?
    private var originalFocusedApp: NSRunningApplication?
    
    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }
    
    // Store the currently focused app before recording starts
    func storeCurrentFocusedApp() {
        originalFocusedApp = NSWorkspace.shared.frontmostApplication
        print("📱 Stored focused app: \(originalFocusedApp?.localizedName ?? "Unknown")")
    }
    
    func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("📋 Copied to clipboard: \(text)")
    }
    
    func simulatePasteKeystroke() {
        // First ensure the original app gets focus back
        if let originalApp = originalFocusedApp {
            print("🔄 Restoring focus to: \(originalApp.localizedName ?? "Unknown")")
            originalApp.activate(options: [.activateIgnoringOtherApps])
            
            // Give the app time to regain focus, then paste
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.performPasteWithRetry()
            }
        } else {
            // Fallback: wait longer and try pasting
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                self.performPasteWithRetry()
            }
        }
    }
    
    private func performPasteWithRetry() {
        let frontApp = NSWorkspace.shared.frontmostApplication
        print("🎯 Attempting to paste into: \(frontApp?.localizedName ?? "Unknown app")")
        
        // Try multiple paste methods with retry
        if !performPasteKeystroke() {
            print("⚠️ CGEvent paste failed, trying AppleScript...")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.pasteUsingAppleScript()
            }
        }
    }
    
    private func performPasteKeystroke() -> Bool {
        // Check if we have accessibility permission
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("❌ No accessibility permission for keystroke simulation")
            return false
        }
        
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            print("❌ Failed to create event source")
            return false
        }
        
        // Create Cmd+V key events
        guard let keyVDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: true), // 'v' key
              let keyVUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0x09, keyDown: false) else {
            print("❌ Failed to create keyboard events")
            return false
        }
        
        // Add Command modifier
        keyVDown.flags = .maskCommand
        keyVUp.flags = .maskCommand
        
        // Post the events
        keyVDown.post(tap: .cgSessionEventTap)
        keyVUp.post(tap: .cgSessionEventTap)
        
        print("✅ Simulated Cmd+V keystroke")
        return true
    }
    
    // Alternative method using NSWorkspace for pasting
    func simulatePasteUsingWorkspace() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Get the currently active application
            if let activeApp = NSWorkspace.shared.frontmostApplication {
                print("Active app: \(activeApp.localizedName ?? "Unknown")")
                
                // Use AppleScript to paste
                self.pasteUsingAppleScript()
            }
        }
    }
    
    private func pasteUsingAppleScript() {
        let script = """
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            
            if let error = error {
                print("AppleScript error: \(error)")
            } else {
                print("Successfully executed paste via AppleScript")
            }
        }
    }
    
    // Method to get current clipboard content
    func getClipboardContent() -> String? {
        let pasteboard = NSPasteboard.general
        return pasteboard.string(forType: .string)
    }
    
    // Method to simulate typing text directly
    func simulateTyping(text: String) {
        guard let eventSource = CGEventSource(stateID: .combinedSessionState) else {
            print("Failed to create event source")
            return
        }
        
        for char in text {
            if let unicodeScalar = char.unicodeScalars.first {
                let keyCode = unicodeScalar.value
                
                let keyDown = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false)
                
                keyDown?.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
                keyUp?.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
                
                keyDown?.post(tap: .cgSessionEventTap)
                keyUp?.post(tap: .cgSessionEventTap)
                
                // Small delay between characters
                usleep(10000) // 10ms delay
            }
        }
    }
} 