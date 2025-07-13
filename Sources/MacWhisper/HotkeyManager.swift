import Cocoa
import Carbon

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isRecording = false
    private weak var settingsManager: SettingsManager?
    
    var onHotkeyPressed: (() -> Void)?
    var onHotkeyReleased: (() -> Void)?
    
    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        setupCarbonHotkey()
    }
    
    deinit {
        cleanup()
    }
    
    private func setupCarbonHotkey() {
        // Create event handler for hotkey events
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let handler: EventHandlerProcPtr = { (nextHandler, theEvent, userData) -> OSStatus in
            // Get the HotkeyManager instance from userData
            let hotkeyManager = unsafeBitCast(userData, to: HotkeyManager.self)
            
            // Get the hotkey ID from the event
            var hotkeyId = EventHotKeyID()
            let result = GetEventParameter(theEvent, 
                                         EventParamName(kEventParamDirectObject),
                                         EventParamType(typeEventHotKeyID),
                                         nil,
                                         MemoryLayout<EventHotKeyID>.size,
                                         nil,
                                         &hotkeyId)
            
            if result == noErr && hotkeyId.signature == OSType(0x4D574852) {
                if hotkeyId.id == 1 {
                    // Start recording
                    if !hotkeyManager.isRecording {
                        hotkeyManager.isRecording = true
                        DispatchQueue.main.async {
                            hotkeyManager.onHotkeyPressed?()
                        }
                    }
                } else if hotkeyId.id == 2 {
                    // Stop recording
                    if hotkeyManager.isRecording {
                        hotkeyManager.isRecording = false
                        DispatchQueue.main.async {
                            hotkeyManager.onHotkeyReleased?()
                        }
                    }
                }
            }
            
            return noErr
        }
        
        // Install the event handler
        let userData = unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                       handler,
                                       1,
                                       &eventType,
                                       userData,
                                       &eventHandler)
        
        if status != noErr {
            print("Failed to install event handler: \(status)")
            return
        }
        
        // Register hotkey based on settings
        let hotkeyDownId = EventHotKeyID(signature: OSType(0x4D574852), id: 1)
        let keyCode = settingsManager?.hotkeyKeyCode ?? 49
        let modifiers = settingsManager?.hotkeyModifiers ?? .control
        
        let carbonModifiers = convertToCarbonModifiers(modifiers)
        let downResult = RegisterEventHotKey(UInt32(keyCode),
                                           carbonModifiers,
                                           hotkeyDownId,
                                           GetApplicationEventTarget(),
                                           0,
                                           &hotKeyRef)
        
        if downResult != noErr {
            print("❌ Failed to register hotkey: \(downResult)")
        } else {
            let hotkeyDesc = settingsManager?.getHotkeyDescription() ?? "Control + Space"
            print("✅ Global hotkey registered successfully!")
            print("📝 Press and hold \(hotkeyDesc) to record")
        }
        
        // Setup key release monitoring with NSEvent since Carbon doesn't handle key release well
        setupKeyReleaseMonitoring()
    }
    
    private func setupKeyReleaseMonitoring() {
        // Monitor for key release events globally
        NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyRelease(event)
        }
        
        // Monitor for key release events locally as well
        NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyRelease(event)
            return event
        }
    }
    
    private func handleKeyRelease(_ event: NSEvent) {
        guard isRecording else { return }
        
        let currentKeyCode = settingsManager?.hotkeyKeyCode ?? 49
        let currentModifiers = settingsManager?.hotkeyModifiers ?? .control
        let isCurrentKeyPressed = event.keyCode == currentKeyCode
        let isCurrentModifierPressed = event.modifierFlags.contains(currentModifiers)
        
        // Stop recording when either the key or modifier is released
        if (event.type == .keyUp && isCurrentKeyPressed) || 
           (event.type == .flagsChanged && !isCurrentModifierPressed) {
            isRecording = false
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyReleased?()
            }
        }
    }
    
    private func cleanup() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    
    func updateHotkey() {
        print("🔄 Updating hotkey configuration...")
        cleanup()
        setupCarbonHotkey()
    }
    
    private func convertToCarbonModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        
        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }
        
        return carbonModifiers
    }
} 