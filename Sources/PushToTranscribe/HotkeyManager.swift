import Cocoa
import Carbon

enum HotkeyType {
    case normal
    case cleanup
}

class HotkeyManager {
    private var primaryHotKeyRef: EventHotKeyRef?
    private var cleanupHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isRecording = false
    private var currentHotkeyType: HotkeyType = .normal
    private weak var settingsManager: SettingsManager?
    private let logger = DiagnosticLogger.shared
    
    // Callbacks now include the hotkey type
    var onHotkeyPressed: ((HotkeyType) -> Void)?
    var onHotkeyReleased: ((HotkeyType) -> Void)?
    
    // Hotkey IDs
    private let primaryHotkeyId: UInt32 = 1
    private let cleanupHotkeyId: UInt32 = 3  // Using 3 to avoid conflict with old id 2
    private let hotkeySignature: OSType = 0x4D574852
    
    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        setupCarbonHotkeys()
    }
    
    deinit {
        cleanup()
    }
    
    private func setupCarbonHotkeys() {
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
            
            if result == noErr && hotkeyId.signature == hotkeyManager.hotkeySignature {
                if !hotkeyManager.isRecording {
                    hotkeyManager.isRecording = true
                    
                    // Determine which hotkey was pressed
                    if hotkeyId.id == hotkeyManager.primaryHotkeyId {
                        hotkeyManager.currentHotkeyType = .normal
                        hotkeyManager.logger.info("Primary hotkey pressed (normal mode)", category: "Hotkey")
                    } else if hotkeyId.id == hotkeyManager.cleanupHotkeyId {
                        hotkeyManager.currentHotkeyType = .cleanup
                        hotkeyManager.logger.info("Cleanup hotkey pressed (cleanup mode)", category: "Hotkey")
                    }
                    
                    DispatchQueue.main.async {
                        hotkeyManager.onHotkeyPressed?(hotkeyManager.currentHotkeyType)
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
            logger.error("Failed to install event handler: \(status)", category: "Hotkey")
            return
        }
        
        // Register primary hotkey
        registerPrimaryHotkey()
        
        // Register cleanup hotkey if enabled
        registerCleanupHotkey()
        
        // Setup key release monitoring with NSEvent since Carbon doesn't handle key release well
        setupKeyReleaseMonitoring()
    }
    
    private func registerPrimaryHotkey() {
        let hotkeyDownId = EventHotKeyID(signature: hotkeySignature, id: primaryHotkeyId)
        let keyCode = settingsManager?.hotkeyKeyCode ?? 49
        let modifiers = settingsManager?.hotkeyModifiers ?? .control
        
        let carbonModifiers = convertToCarbonModifiers(modifiers)
        let result = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotkeyDownId,
                                        GetApplicationEventTarget(),
                                        0,
                                        &primaryHotKeyRef)
        
        if result != noErr {
            logger.error("Failed to register primary hotkey: \(result)", category: "Hotkey")
        } else {
            let hotkeyDesc = settingsManager?.getHotkeyDescription() ?? "Control + Space"
            logger.success("Primary hotkey registered: \(hotkeyDesc)", category: "Hotkey")
            print("✅ Primary hotkey registered: \(hotkeyDesc)")
        }
    }
    
    private func registerCleanupHotkey() {
        guard settingsManager?.cleanupHotkeyEnabled == true else {
            logger.info("Cleanup hotkey is disabled", category: "Hotkey")
            return
        }
        
        let hotkeyDownId = EventHotKeyID(signature: hotkeySignature, id: cleanupHotkeyId)
        let keyCode = settingsManager?.cleanupHotkeyKeyCode ?? 49
        let modifiers = settingsManager?.cleanupHotkeyModifiers ?? .option
        
        let carbonModifiers = convertToCarbonModifiers(modifiers)
        let result = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotkeyDownId,
                                        GetApplicationEventTarget(),
                                        0,
                                        &cleanupHotKeyRef)
        
        if result != noErr {
            logger.error("Failed to register cleanup hotkey: \(result)", category: "Hotkey")
        } else {
            let hotkeyDesc = settingsManager?.getCleanupHotkeyDescription() ?? "Option + Space"
            logger.success("Cleanup hotkey registered: \(hotkeyDesc)", category: "Hotkey")
            print("✅ Cleanup hotkey registered: \(hotkeyDesc)")
        }
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
        
        // Get the key code and modifiers for the current hotkey type
        let currentKeyCode: UInt16
        let currentModifiers: NSEvent.ModifierFlags
        
        switch currentHotkeyType {
        case .normal:
            currentKeyCode = settingsManager?.hotkeyKeyCode ?? 49
            currentModifiers = settingsManager?.hotkeyModifiers ?? .control
        case .cleanup:
            currentKeyCode = settingsManager?.cleanupHotkeyKeyCode ?? 49
            currentModifiers = settingsManager?.cleanupHotkeyModifiers ?? .option
        }
        
        let isCurrentKeyPressed = event.keyCode == currentKeyCode
        let isCurrentModifierPressed = event.modifierFlags.contains(currentModifiers)
        
        // Stop recording when either the key or modifier is released
        if (event.type == .keyUp && isCurrentKeyPressed) || 
           (event.type == .flagsChanged && !isCurrentModifierPressed) {
            isRecording = false
            let releasedType = currentHotkeyType
            logger.info("Hotkey released (\(releasedType == .cleanup ? "cleanup" : "normal") mode)", category: "Hotkey")
            DispatchQueue.main.async { [weak self] in
                self?.onHotkeyReleased?(releasedType)
            }
        }
    }
    
    private func cleanup() {
        if let hotKeyRef = primaryHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.primaryHotKeyRef = nil
        }
        
        if let hotKeyRef = cleanupHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.cleanupHotKeyRef = nil
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
    
    func updateHotkey() {
        logger.info("Updating hotkey configuration...", category: "Hotkey")
        print("🔄 Updating hotkey configuration...")
        cleanup()
        setupCarbonHotkeys()
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
