import Cocoa
import Carbon

enum HotkeyType {
    case normal
    case cleanup
}

class HotkeyManager {
    /// A press that is currently held. Exactly one can exist at a time, and it
    /// is the single source of truth for "are we recording".
    ///
    /// This replaced three separate booleans (`isRecording`, `capsLockDown`,
    /// `startedWithCapsLock`) written from the Carbon handler thread, the tap
    /// thread and the main thread. They could disagree — most damagingly
    /// `isRecording == true` with `startedWithCapsLock == false`, which made
    /// every subsequent Caps Lock press get silently swallowed until the app
    /// was restarted.
    private struct Session {
        enum Source { case capsLock, carbon }
        let type: HotkeyType
        let source: Source
        let startedAt: Date
    }

    private var primaryHotKeyRef: EventHotKeyRef?
    private var cleanupHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private weak var settingsManager: SettingsManager?
    private let logger = DiagnosticLogger.shared

    /// Guards `session`, which is read from the tap thread's watchdog.
    private let stateLock = NSLock()
    private var session: Session?

    // The Caps Lock tap lives on its own thread so a busy main thread can never
    // cause the system to disable it. See `setupCapsLockTap`.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var tapThreadExited: DispatchSemaphore?
    private let watchdogInterval: CFTimeInterval = 1.0

    // Tap-thread-only state. Never read or written from any other thread.
    private var lastRemapPush = Date.distantPast
    private var lastSecureInputState = false
    private var ticksKeyLookedReleased = 0
    /// Start time of the session the flag below belongs to.
    private var reconciledSessionStart: Date?
    /// Whether the window server has reported F18 as down during this session.
    private var keyStateSeenDown = false

    private var wakeObservers: [NSObjectProtocol] = []

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
        cleanup()
        setupHotkeys()
    }

    func restoreSystemCapsLock() {
        CapsLockHIDRemap.restoreIfNeeded()
    }

    private var isPrimaryCapsLock: Bool {
        settingsManager?.isPrimaryCapsLock == true
    }

    // MARK: - Session state

    /// Opens a session unless one is already open. Main thread only.
    private func beginSession(type: HotkeyType, source: Session.Source) {
        stateLock.lock()
        if let existing = session {
            stateLock.unlock()
            logger.warning("Press ignored — a \(existing.source) session is already open", category: "Hotkey")
            return
        }
        session = Session(type: type, source: source, startedAt: Date())
        stateLock.unlock()

        logger.info("\(source) pressed (\(type == .cleanup ? "cleanup" : "normal") mode)", category: "Hotkey")
        onHotkeyPressed?(type)
    }

    /// Closes the open session if it came from `source`. Main thread only.
    /// Calling it with no session open is a no-op, which is what every recovery
    /// path wants.
    private func endSession(source: Session.Source, reason: String) {
        stateLock.lock()
        guard let open = session, open.source == source else {
            stateLock.unlock()
            return
        }
        session = nil
        stateLock.unlock()

        logger.info("\(source) \(reason) after \(String(format: "%.1f", Date().timeIntervalSince(open.startedAt)))s", category: "Hotkey")
        onHotkeyReleased?(open.type)
    }

    /// Drops any open session without firing a release. Only for teardown.
    private func discardSession() {
        stateLock.lock()
        session = nil
        stateLock.unlock()
    }

    private var openCapsLockSession: Session? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let open = session, open.source == .capsLock else { return nil }
        return open
    }

    private var hasOpenSession: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return session != nil
    }

    // MARK: - Setup

    private func setupHotkeys() {
        setupCarbonHotkeys()

        if isPrimaryCapsLock {
            CapsLockHIDRemap.apply()
            logger.info("Caps Lock→F18 HID mapping active: \(CapsLockHIDRemap.isMappingActive())", category: "Hotkey")
            setupCapsLockTap()
            observeWakeNotifications()
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
            let manager = unsafeBitCast(userData, to: HotkeyManager.self)

            var hotkeyId = EventHotKeyID()
            let result = GetEventParameter(theEvent,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &hotkeyId)

            guard result == noErr, hotkeyId.signature == manager.hotkeySignature else { return noErr }

            let type: HotkeyType = hotkeyId.id == manager.cleanupHotkeyId ? .cleanup : .normal
            // Session state is main-thread-owned; never mutate it from here.
            DispatchQueue.main.async {
                manager.beginSession(type: type, source: .carbon)
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

        let result = RegisterEventHotKey(UInt32(keyCode),
                                         convertToCarbonModifiers(modifiers),
                                         hotkeyDownId,
                                         GetApplicationEventTarget(),
                                         0,
                                         &primaryHotKeyRef)

        if result != noErr {
            logger.error("Failed to register primary hotkey: \(result)", category: "Hotkey")
        } else {
            logger.success("Primary hotkey registered: \(settingsManager?.getHotkeyDescription() ?? "Control + Space")", category: "Hotkey")
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

        let result = RegisterEventHotKey(UInt32(keyCode),
                                         convertToCarbonModifiers(modifiers),
                                         hotkeyDownId,
                                         GetApplicationEventTarget(),
                                         0,
                                         &cleanupHotKeyRef)

        if result != noErr {
            logger.error("Failed to register cleanup hotkey: \(result)", category: "Hotkey")
        } else {
            logger.success("Cleanup hotkey registered: \(settingsManager?.getCleanupHotkeyDescription() ?? "Option + Space")", category: "Hotkey")
        }
    }

    // MARK: - Caps Lock tap

    /// Runs the Caps Lock event tap on a dedicated thread rather than the main
    /// run loop.
    ///
    /// macOS disables an event tap whose callback does not return within about
    /// a second, and the main run loop is exactly where long stalls happen.
    /// When that hit mid-press the key-up was never delivered and the state
    /// machine was left believing the key was still held, so the next press was
    /// silently swallowed.
    private func setupCapsLockTap() {
        let exited = DispatchSemaphore(value: 0)
        tapThreadExited = exited

        let thread = Thread { [weak self] in
            guard let self = self else {
                exited.signal()
                return
            }
            self.tapRunLoop = CFRunLoopGetCurrent()

            guard self.installCapsLockTap() else {
                exited.signal()
                return
            }

            // A bounded run gives the watchdog a tick even during long stretches
            // with no key events at all.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, self.watchdogInterval, false)
                self.runWatchdog()
            }

            self.teardownCapsLockTap()
            exited.signal()
        }
        thread.name = "com.pushToTranscribe.capsLockTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    /// Creates the tap and attaches it to the calling thread's run loop.
    /// Called on the tap thread only.
    private func installCapsLockTap() -> Bool {
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

        var tapKind = "HID"
        var tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: userInfo
        )
        if tap == nil {
            tapKind = "session"
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: userInfo
            )
        }

        guard let tap = tap else {
            logger.error("Failed to create Caps Lock event tap. Grant Accessibility permission and restart.", category: "Hotkey")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        lastSecureInputState = IsSecureEventInputEnabled()
        logger.success("Caps Lock→F18 intercept registered on \(tapKind) tap, dedicated thread (secure input: \(lastSecureInputState))", category: "Hotkey")
        return true
    }

    /// Called on the tap thread only.
    private func teardownCapsLockTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
    }

    /// The tap callback. Must return fast: anything slower than ~1s here gets
    /// the tap disabled by the system, so it does no logging and no work beyond
    /// reading the key code.
    private func handleCapsLockTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            let reason = type == .tapDisabledByTimeout ? "callback timeout" : "user input"
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.logger.warning("Caps Lock event tap was disabled (\(reason)) and re-enabled", category: "Hotkey")
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

        // Swallow autorepeat without disturbing the state machine.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return nil }

        let isDown = type == .keyDown
        let optionHeld = event.flags.contains(.maskAlternate)
        DispatchQueue.main.async { [weak self] in
            self?.handleCapsLock(isDown: isDown, optionHeld: optionHeld)
        }

        // Swallow F18 so it never reaches other apps.
        return nil
    }

    /// Main thread only.
    private func handleCapsLock(isDown: Bool, optionHeld: Bool) {
        guard isPrimaryCapsLock else { return }

        if isDown {
            // A session still open at key-down means its key-up went missing.
            // Close it unconditionally so this press is honoured rather than
            // swallowed — the old code could leave the session wedged forever.
            if hasOpenSession {
                logger.warning("Caps Lock down with a session still open — recovering", category: "Hotkey")
                endSession(source: .capsLock, reason: "recovered from a lost key-up")
                endSession(source: .carbon, reason: "superseded by Caps Lock")
            }

            let useCleanup = optionHeld && settingsManager?.cleanupHotkeyEnabled == true
            beginSession(type: useCleanup ? .cleanup : .normal, source: .capsLock)
        } else {
            endSession(source: .capsLock, reason: "released")
        }
    }

    /// Periodic health check, on the tap thread so a stalled main thread cannot
    /// stop it running.
    private func runWatchdog() {
        guard let tap = eventTap else { return }

        if !CGEvent.tapIsEnabled(tap: tap) {
            logger.warning("Watchdog: Caps Lock event tap was disabled — re-enabling", category: "Hotkey")
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        let secureInput = IsSecureEventInputEnabled()
        if secureInput != lastSecureInputState {
            lastSecureInputState = secureInput
            if secureInput {
                logger.warning("Secure event input turned on by another app — Caps Lock presses will not reach the tap until it turns off", category: "Hotkey")
            } else {
                logger.info("Secure event input turned off", category: "Hotkey")
            }
        }

        reconcileWithPhysicalKey()

        // Never touch the HID mapping while the key is held.
        guard openCapsLockSession == nil else { return }

        if !CapsLockHIDRemap.isMappingActive() {
            logger.error("Watchdog: Caps Lock→F18 HID mapping was lost — reapplying", category: "Hotkey")
            let ok = CapsLockHIDRemap.reapply()
            lastRemapPush = Date()
            logger.info("Watchdog: HID mapping reapply \(ok ? "succeeded" : "FAILED")", category: "Hotkey")
        } else if Date().timeIntervalSince(lastRemapPush) > 60 {
            // Idempotent, and picks up keyboards attached since the last push.
            lastRemapPush = Date()
            CapsLockHIDRemap.reapply()
        }
    }

    /// The backstop for a key-up that never arrived: ask the window server
    /// whether the key is actually still down.
    ///
    /// Every other recovery path needs the user to press Caps Lock again, which
    /// means they only find out something is wrong by losing a recording. This
    /// notices within a second, and is what stops a dropped key-up from
    /// recording until the app is quit.
    private func reconcileWithPhysicalKey() {
        guard let open = openCapsLockSession else {
            ticksKeyLookedReleased = 0
            reconciledSessionStart = nil
            keyStateSeenDown = false
            return
        }

        if reconciledSessionStart != open.startedAt {
            reconciledSessionStart = open.startedAt
            keyStateSeenDown = false
            ticksKeyLookedReleased = 0
        }

        // Give the press a moment to settle before trusting the key state.
        guard Date().timeIntervalSince(open.startedAt) > 1.0 else {
            ticksKeyLookedReleased = 0
            return
        }

        let key = CGKeyCode(CapsLockHIDRemap.f18KeyCode)
        let keyDown = CGEventSource.keyState(.combinedSessionState, key: key)
            || CGEventSource.keyState(.hidSystemState, key: key)
        if keyDown {
            keyStateSeenDown = true
            ticksKeyLookedReleased = 0
            return
        }

        // The tap swallows F18, so the window server may never record it as
        // down at all — in which case "released" is the only thing it can ever
        // report and says nothing about the physical key. Trust a release only
        // once the key state has shown the key held during this session;
        // otherwise every recording would be cut off after a few seconds.
        guard keyStateSeenDown else { return }

        // Cutting a recording short mid-sentence is worse than leaving a stuck
        // one for another second, so act only on sustained disagreement rather
        // than a single sample.
        ticksKeyLookedReleased += 1
        guard ticksKeyLookedReleased >= 3 else { return }
        ticksKeyLookedReleased = 0

        logger.warning("Watchdog: Caps Lock has read as released for 3s but the session is still open — closing it", category: "Hotkey")
        DispatchQueue.main.async { [weak self] in
            self?.endSession(source: .capsLock, reason: "released (recovered by watchdog)")
        }
    }

    /// Re-push the HID mapping as soon as the machine wakes or the session comes
    /// back, rather than waiting for the watchdog to notice.
    private func observeWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]

        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                let ok = CapsLockHIDRemap.reapply()
                self.logger.info("Reapplied Caps Lock→F18 mapping after \(name.rawValue): \(ok ? "ok" : "FAILED")", category: "Hotkey")
                // Sleeping mid-press eats the key-up.
                self.endSession(source: .capsLock, reason: "released (recovered after wake)")
            }
            wakeObservers.append(observer)
        }
    }

    // MARK: - Non-Caps-Lock release monitoring

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
        stateLock.lock()
        let open = session
        stateLock.unlock()
        guard let open = open, open.source == .carbon else { return }

        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        switch open.type {
        case .normal:
            keyCode = settingsManager?.hotkeyKeyCode ?? 49
            modifiers = settingsManager?.hotkeyModifiers ?? .control
        case .cleanup:
            keyCode = settingsManager?.cleanupHotkeyKeyCode ?? 49
            modifiers = settingsManager?.cleanupHotkeyModifiers ?? .option
        }

        let keyReleased = event.type == .keyUp && event.keyCode == keyCode
        let modifierReleased = event.type == .flagsChanged && !event.modifierFlags.contains(modifiers)

        guard keyReleased || modifierReleased else { return }
        endSession(source: .carbon, reason: "released")
    }

    // MARK: - Teardown

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

        // The tap thread owns the mach port and the run-loop source, so let it
        // tear them down rather than racing it from here.
        if let runLoop = tapRunLoop {
            tapThread?.cancel()
            CFRunLoopStop(runLoop)
            _ = tapThreadExited?.wait(timeout: .now() + 1.0)
        }
        tapRunLoop = nil
        tapThread = nil
        tapThreadExited = nil
        eventTap = nil
        runLoopSource = nil

        let center = NSWorkspace.shared.notificationCenter
        for observer in wakeObservers {
            center.removeObserver(observer)
        }
        wakeObservers.removeAll()

        CapsLockHIDRemap.restoreIfNeeded()

        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        discardSession()
    }

    private func convertToCarbonModifiers(_ modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        return carbonModifiers
    }
}
