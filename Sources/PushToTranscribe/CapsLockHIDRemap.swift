import Foundation
import CoreGraphics
import IOKit.hid

/// Remaps Caps Lock to F18 at the HID driver (Apple TN2450).
/// That disables the lock, LED, and on-screen indicator while leaving a
/// normal key-down/key-up the app can use for push-to-talk.
enum CapsLockHIDRemap {
    /// Carbon kVK_F18
    static let f18KeyCode: UInt16 = 0x4F
    
    private static let capsLockUsage: UInt64 = 0x700000039
    private static let f18Usage: UInt64 = 0x70000006D
    private static var applied = false
    
    static func apply() {
        turnOffCapsLockIfEngaged()
        let map = mapping(from: capsLockUsage, to: f18Usage)
        if setUserKeyMapping(map) {
            applied = true
            print("✅ Caps Lock remapped to F18 (LED/lock disabled)")
            return
        }
        if runHidutil(mapJSON: hidutilJSON(from: capsLockUsage, to: f18Usage)) {
            applied = true
            print("✅ Caps Lock remapped to F18 via hidutil")
            return
        }
        print("❌ Failed to remap Caps Lock to F18")
    }
    
    static func restoreIfNeeded() {
        guard applied else { return }
        if setUserKeyMapping([]) || runHidutil(mapJSON: "{\"UserKeyMapping\":[]}") {
            print("✅ Caps Lock HID remap restored")
        } else {
            print("❌ Failed to restore Caps Lock HID remap")
        }
        applied = false
    }
    
    private static func mapping(from src: UInt64, to dst: UInt64) -> [[String: NSNumber]] {
        [[
            "HIDKeyboardModifierMappingSrc": NSNumber(value: src),
            "HIDKeyboardModifierMappingDst": NSNumber(value: dst)
        ]]
    }
    
    private static func setUserKeyMapping(_ map: [[String: NSNumber]]) -> Bool {
        let system = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(system) else {
            print("❌ IOHIDEventSystemClientCopyServices failed")
            return false
        }
        
        var updated = 0
        let count = CFArrayGetCount(services)
        for i in 0..<count {
            let raw = CFArrayGetValueAtIndex(services, i)!
            let service = Unmanaged<IOHIDServiceClient>.fromOpaque(raw).takeUnretainedValue()
            let isKeyboard = IOHIDServiceClientConformsTo(
                service,
                UInt32(kHIDPage_GenericDesktop),
                UInt32(kHIDUsage_GD_Keyboard)
            ) != 0
            guard isKeyboard else { continue }
            if IOHIDServiceClientSetProperty(service, "UserKeyMapping" as CFString, map as CFArray) {
                updated += 1
            }
        }
        print("HID UserKeyMapping applied to \(updated) keyboard service(s)")
        return updated > 0
    }
    
    private static func hidutilJSON(from src: UInt64, to dst: UInt64) -> String {
        "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(src),\"HIDKeyboardModifierMappingDst\":\(dst)}]}"
    }
    
    private static func turnOffCapsLockIfEngaged() {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        guard flags.contains(.maskAlphaShift) else { return }
        
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 57, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
    
    private static func runHidutil(mapJSON json: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print("hidutil: \(text)")
            }
            return process.terminationStatus == 0
        } catch {
            print("❌ hidutil remap failed: \(error)")
            return false
        }
    }
}
