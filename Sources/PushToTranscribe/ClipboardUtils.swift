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
    

    

    
    // Try paste methods with proper fallback
    func pasteTextWithFallback(text: String) {
        // 1. Set clipboard text
        copyToClipboard(text: text)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // 2. Wait for clipboard to be ready (reduced delay)
            Thread.sleep(forTimeInterval: 0.2)
            
            // 3. Try Apple Events first (often most reliable)
            if self.tryAppleEventsPaste() {
                return // Success, don't try other methods
            }
            
            // 4. If Apple Events failed, try CGEvent as backup
            Thread.sleep(forTimeInterval: 0.1)
            self.tryCGEventPaste()
        }
    }
    
    // Returns true if successful, false if failed
    private func tryAppleEventsPaste() -> Bool {
        let script = """
        tell application "System Events"
            keystroke "v" using {command down}
        end tell
        """
        
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            
            if error == nil {
                return true // Success
            }
        }
        return false // Failed
    }
    
    // Simplified CGEvent paste
    private func tryCGEventPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        
        keyDown?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.02) // Very brief delay
        keyUp?.post(tap: .cghidEventTap)
    }
    
    func pasteTextAutomatically(text: String) {
        // Use the improved fallback approach
        pasteTextWithFallback(text: text)
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
    

    

} 