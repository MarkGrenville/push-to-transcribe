import Cocoa
import CoreGraphics
import ApplicationServices

class ClipboardUtils {
    private var originalFocusedApp: NSRunningApplication?
    
    func storeCurrentFocusedApp() {
        originalFocusedApp = NSWorkspace.shared.frontmostApplication
    }
    
    func copyToClipboard(text: String) {
        // Ensure clipboard operations happen on main thread but don't block
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }
    
    func simulatePasteKeystroke() {
        // Dispatch to background thread to avoid main thread blocking
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait 0.3 seconds to ensure clipboard is ready
            Thread.sleep(forTimeInterval: 0.3)
            
            // Perform keystroke simulation on background thread
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
            
            keyDown?.flags = .maskCommand
            keyUp?.flags = .maskCommand
            
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
            
            // Try to restore focus after delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if let app = self.originalFocusedApp {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }
    }
    
    // Apple Events approach - often more reliable than CGEvent
    func simulatePasteWithAppleEvents() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait for clipboard to be ready
            Thread.sleep(forTimeInterval: 0.3)
            
            let script = """
            tell application "System Events"
                keystroke "v" using {command down}
            end tell
            """
            
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
                
                if let error = error {
                    print("🚨 Apple Events paste failed: \(error)")
                    // Fallback to CGEvent approach
                    self.simulatePasteKeystroke()
                } else {
                    print("✅ Apple Events paste succeeded")
                }
            } else {
                print("🚨 Failed to create Apple Script")
                // Fallback to CGEvent approach
                self.simulatePasteKeystroke()
            }
        }
    }
    
    // Enhanced CGEvent approach with better key handling
    func simulatePasteWithCGEvent() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Wait for clipboard to be ready
            Thread.sleep(forTimeInterval: 0.3)
            
            // Create more precise key events for Cmd+V
            let source = CGEventSource(stateID: .hidSystemState)
            
            // Key down for 'v' with command modifier
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            keyDown?.flags = .maskCommand
            
            // Key up for 'v' with command modifier
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            keyUp?.flags = .maskCommand
            
            // Post the events
            keyDown?.post(tap: .cghidEventTap)
            // Small delay between key down and up
            Thread.sleep(forTimeInterval: 0.05)
            keyUp?.post(tap: .cghidEventTap)
            
            print("✅ Enhanced CGEvent paste attempted")
        }
    }
    
    // Try multiple paste methods in sequence
    func pasteTextWithMultipleMethods(text: String) {
        // 1. Set clipboard text
        copyToClipboard(text: text)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 2. Wait for clipboard to be ready
            Thread.sleep(forTimeInterval: 0.3)
            
            // 3. Try Apple Events first (often most reliable)
            print("🔄 Trying Apple Events paste...")
            self.simulatePasteWithAppleEvents()
            
            // 4. Wait a bit and try CGEvent as backup
            Thread.sleep(forTimeInterval: 0.5)
            print("🔄 Trying enhanced CGEvent paste as backup...")
            self.simulatePasteWithCGEvent()
        }
    }
    
    func pasteTextAutomatically(text: String) {
        // Use the multi-method approach for better reliability
        pasteTextWithMultipleMethods(text: text)
    }
    
    func getClipboardContent() -> String? {
        // Ensure clipboard read happens on main thread
        var result: String?
        DispatchQueue.main.sync {
            let pasteboard = NSPasteboard.general
            result = pasteboard.string(forType: .string)
        }
        return result
    }
    
    func testPasteManually() {
        // Dispatch to background thread to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async {
            self.copyToClipboard(text: "Manual test paste")
            Thread.sleep(forTimeInterval: 0.3)
            self.simulatePasteKeystroke()
        }
    }
    
    func simulateTyping(text: String) {
        // Dispatch to background thread to avoid main thread blocking
        DispatchQueue.global(qos: .userInitiated).async {
            for char in text {
                let charString = String(char)
                let keyCode = self.getKeyCodeForCharacter(charString)
                
                if let keyCode = keyCode {
                    let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)
                    let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
                    
                    keyDown?.post(tap: .cghidEventTap)
                    keyUp?.post(tap: .cghidEventTap)
                    
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }
    
    private func getKeyCodeForCharacter(_ character: String) -> CGKeyCode? {
        let keyCodeMap: [String: CGKeyCode] = [
            "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E,
            "f": 0x03, "g": 0x05, "h": 0x04, "i": 0x22, "j": 0x26,
            "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F,
            "p": 0x23, "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11,
            "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07, "y": 0x10,
            "z": 0x06, " ": 0x31
        ]
        
        return keyCodeMap[character.lowercased()]
    }
} 