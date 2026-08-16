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
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isRecording = false
    private var capsLockDown = false
    private var startedWithCapsLock = false
    private var currentHotkeyType: HotkeyType = .normal
    private weak var settingsManager: SettingsManager?
    private let logger = DiagnosticLogger.shared
    
    var onHotkeyPressed: ((HotkeyType) -> Void)?
    var onHotkeyReleased: ((HotkeyType) -> Void)?
    
    private let primaryHotkeyId: UInt32 = 1
    private let cleanupHotkeyId: UInt32 = 3
    private let hotkeySignature: OSType = 0x4D574852
    
    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
        setupHotkeys()
    }
    
    deinit {
        cleanup()
    }
    
    func updateHotkey() {
        logger.info("Updating hotkey configuration...", category: "Hotkey")
        print("🔄 Updating hotkey configuration...")
        cleanup()
        setupHotkeys()
    }
    
    func restoreSystemCapsLock() {
        CapsLockHIDRemap.restoreIfNeeded()
    }
    
    private var isPrimaryCapsLock: Bool {
        settingsManager?.isPrimaryCapsLock == true
    }
    
    private func setupHotkeys() {
        setupCarbonHotkeys()
        
        if isPrimaryCapsLock {
            CapsLockHIDRemap.apply()
            setupCapsLockTap()
        } else {
            registerPrimaryHotkey()
        }
        
        registerCleanupHotkey()
        setupKeyReleaseMonitoring()
    }
    
    private func setupCarbonHotkeys() {
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)
        
        let handler: EventHandlerProcPtr = { (_, theEvent, userData) -> OSStatus in
            let hotkeyManager = unsafeBitCast(userData, to: HotkeyManager.self)
            
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
        
        let userData = unsafeBitCast(self, to: UnsafeMutableRawPointer.self)
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                       handler,
                                       1,
                                       &eventType,
                                       userData,
                                       &eventHandler)
        
        if status != noErr {
            logger.error("Failed to install event handler: \(status)", category: "Hotkey")
        }
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
        
        if settingsManager?.isPrimaryCapsLock == true,
           SettingsManager.isCapsLockHotkey(
            keyCode: settingsManager?.cleanupHotkeyKeyCode ?? 0,
            modifiers: settingsManager?.cleanupHotkeyModifiers ?? []
           ) {
            logger.info("Cleanup hotkey skipped because Caps Lock is the primary hotkey", category: "Hotkey")
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
    
    private func setupCapsLockTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handleCapsLockTap(type: type, event: event)
        }
        
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        ) ?? CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )
        
        guard let tap = tap else {
            logger.error("Failed to create Caps Lock event tap. Grant Accessibility permission and restart.", category: "Hotkey")
            print("❌ Failed to create Caps Lock event tap — check Accessibility permission")
            return
        }
        
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        
        logger.success("Caps Lock→F18 intercept registered (hold to transcribe)", category: "Hotkey")
        print("✅ Caps Lock→F18 intercept registered")
    }
    
    private func handleCapsLockTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                logger.warning("Caps Lock event tap was disabled; re-enabled", category: "Hotkey")
            }
            return Unmanaged.passUnretained(event)
        }
        
        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == CapsLockHIDRemap.f18KeyCode else {
            return Unmanaged.passUnretained(event)
        }
        
        let optionHeld = event.flags.contains(.maskAlternate)
        DispatchQueue.main.async { [weak self] in
            self?.handleCapsLock(isDown: type == .keyDown, optionHeld: optionHeld)
        }
        
        // Swallow F18 so it never reaches other apps.
        return nil
    }
    
    private func handleCapsLock(isDown: Bool, optionHeld: Bool) {
        guard isPrimaryCapsLock else { return }
        guard isDown != capsLockDown else { return }
        capsLockDown = isDown
        
        if isDown {
            guard !isRecording else { return }
            isRecording = true
            startedWithCapsLock = true
            let useCleanup = optionHeld && settingsManager?.cleanupHotkeyEnabled == true
            currentHotkeyType = useCleanup ? .cleanup : .normal
            let mode = useCleanup ? "cleanup" : "normal"
            logger.info("Caps Lock pressed (\(mode) mode)", category: "Hotkey")
            onHotkeyPressed?(currentHotkeyType)
        } else if isRecording && startedWithCapsLock {
            isRecording = false
            startedWithCapsLock = false
            let releasedType = currentHotkeyType
            logger.info("Caps Lock released (\(releasedType == .cleanup ? "cleanup" : "normal") mode)", category: "Hotkey")
            onHotkeyReleased?(releasedType)
        }
    }
    
    private func setupKeyReleaseMonitoring() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyRelease(event)
        }
        
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyRelease(event)
            return event
        }
    }
    
    private func handleKeyRelease(_ event: NSEvent) {
        guard isRecording else { return }
        guard !startedWithCapsLock else { return }
        
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
            primaryHotKeyRef = nil
        }
        
        if let hotKeyRef = cleanupHotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            cleanupHotKeyRef = nil
        }
        
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        
        CapsLockHIDRemap.restoreIfNeeded()
        
        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        
        capsLockDown = false
        startedWithCapsLock = false
        isRecording = false
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
