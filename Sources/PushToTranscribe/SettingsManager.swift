import Foundation
import AppKit
import Combine
import Security

class SettingsManager: ObservableObject {
    // MARK: - Keychain Constants
    private static let keychainService = "com.example.pushtotranscribe"
    private static let keychainAccountAPIKey = "openai-api-key"
    
    // Published properties for UI binding
    @Published var apiKey: String = "" {
        didSet {
            if oldValue != apiKey {
                Self.saveToKeychain(apiKey)
                apiKeyChanged?()
            }
        }
    }
    
    var apiKeyChanged: (() -> Void)?
    
    var hasValidAPIKey: Bool {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // Default to the latest and most accurate model
    @Published var transcriptionModel: String = "gpt-transcribe" {
        didSet { saveSettings() }
    }
    
    @Published var language: String = "en" {
        didSet { saveSettings() }
    }
    
    @Published var showNotifications: Bool = true {
        didSet { saveSettings() }
    }
    
    @Published var copyToClipboard: Bool = true {
        didSet { saveSettings() }
    }
    
    @Published var autoPaste: Bool = true {
        didSet { saveSettings() }
    }
    
    @Published var hotkeyModifiers: NSEvent.ModifierFlags = .control {
        didSet { 
            saveSettings()
            hotkeyChanged?()
        }
    }
    
    @Published var hotkeyKeyCode: UInt16 = 49 { // Space key
        didSet { 
            saveSettings()
            hotkeyChanged?()
        }
    }
    
    // MARK: - Cleanup Hotkey Settings
    
    @Published var cleanupHotkeyEnabled: Bool = true {
        didSet {
            saveSettings()
            hotkeyChanged?()
        }
    }
    
    @Published var cleanupHotkeyModifiers: NSEvent.ModifierFlags = .option {
        didSet {
            saveSettings()
            hotkeyChanged?()
        }
    }
    
    @Published var cleanupHotkeyKeyCode: UInt16 = 49 { // Space key
        didSet {
            saveSettings()
            hotkeyChanged?()
        }
    }
    
    // MARK: - Cleanup LLM Settings
    
    static let defaultCleanupPrompt = """
Clean up the following transcription so it reads clearly and professionally.
• Fix punctuation and sentence structure
• Convert obvious lists into bullet points
• Remove filler words and transcription artifacts
• Do not change the meaning, tone, or intent
• Do not add new content or rewrite creatively

Output only the cleaned version.
"""
    
    @Published var cleanupPrompt: String = SettingsManager.defaultCleanupPrompt {
        didSet { 
            saveSettings()
            saveCleanupPromptToFile() // Also save to persistent file
        }
    }
    
    @Published var cleanupModel: String = "gpt-4o-mini" {
        didSet { saveSettings() }
    }
    
    // File-based storage for cleanup prompt (survives app reinstalls)
    static var appSupportDirectory: URL? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let appDir = appSupport.appendingPathComponent("PushToTranscribe")
        
        // Create directory if it doesn't exist
        if !fileManager.fileExists(atPath: appDir.path) {
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        
        return appDir
    }
    
    // MARK: - Voice Archive
    
    private static var archiveAudioDirectory: URL? {
        guard let base = appSupportDirectory else { return nil }
        let dir = base.appendingPathComponent("voice-archive/audio")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    private static var archiveTranscriptionDirectory: URL? {
        guard let base = appSupportDirectory else { return nil }
        let dir = base.appendingPathComponent("voice-archive/transcriptions")
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
    
    static func generateSessionId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }
    
    func saveAudioToArchive(wavData: Data, sessionId: String) {
        guard let dir = SettingsManager.archiveAudioDirectory else {
            print("Failed to get archive audio directory")
            return
        }
        let fileURL = dir.appendingPathComponent("\(sessionId).wav")
        do {
            try wavData.write(to: fileURL)
            let logger = DiagnosticLogger.shared
            logger.info("Archived audio: \(fileURL.lastPathComponent) (\(wavData.count) bytes)", category: "Archive")
        } catch {
            print("Failed to archive audio: \(error)")
        }
    }
    
    func saveTranscriptionToArchive(text: String, sessionId: String) {
        guard let dir = SettingsManager.archiveTranscriptionDirectory else {
            print("Failed to get archive transcription directory")
            return
        }
        let fileURL = dir.appendingPathComponent("\(sessionId).txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            let logger = DiagnosticLogger.shared
            logger.info("Archived transcription: \(fileURL.lastPathComponent)", category: "Archive")
        } catch {
            print("Failed to archive transcription: \(error)")
        }
    }
    
    struct ArchiveStats {
        var audioFileCount: Int = 0
        var transcriptionFileCount: Int = 0
        var totalBytes: UInt64 = 0
        
        var formattedSize: String {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(totalBytes))
        }
    }
    
    func getArchiveStats() -> ArchiveStats {
        var stats = ArchiveStats()
        let fileManager = FileManager.default
        
        if let audioDir = SettingsManager.archiveAudioDirectory {
            let files = (try? fileManager.contentsOfDirectory(atPath: audioDir.path)) ?? []
            stats.audioFileCount = files.filter { $0.hasSuffix(".wav") }.count
            for file in files {
                let path = audioDir.appendingPathComponent(file).path
                if let attrs = try? fileManager.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64 {
                    stats.totalBytes += size
                }
            }
        }
        
        if let transcriptionDir = SettingsManager.archiveTranscriptionDirectory {
            let files = (try? fileManager.contentsOfDirectory(atPath: transcriptionDir.path)) ?? []
            stats.transcriptionFileCount = files.filter { $0.hasSuffix(".txt") }.count
            for file in files {
                let path = transcriptionDir.appendingPathComponent(file).path
                if let attrs = try? fileManager.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? UInt64 {
                    stats.totalBytes += size
                }
            }
        }
        
        return stats
    }
    
    private static var cleanupPromptFileURL: URL? {
        return appSupportDirectory?.appendingPathComponent("cleanup-prompt.txt")
    }
    
    private func saveCleanupPromptToFile() {
        guard let fileURL = SettingsManager.cleanupPromptFileURL else { return }
        
        do {
            try cleanupPrompt.write(to: fileURL, atomically: true, encoding: .utf8)
            print("💾 Saved cleanup prompt to: \(fileURL.path)")
        } catch {
            print("Failed to save cleanup prompt to file: \(error)")
        }
    }
    
    private func loadCleanupPromptFromFile() -> String? {
        guard let fileURL = SettingsManager.cleanupPromptFileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        
        do {
            let prompt = try String(contentsOf: fileURL, encoding: .utf8)
            print("📂 Loaded cleanup prompt from: \(fileURL.path)")
            return prompt
        } catch {
            print("Failed to load cleanup prompt from file: \(error)")
            return nil
        }
    }
    
    @Published var transcriptionHistory: [TranscriptionEntry] = [] {
        didSet { saveTranscriptionHistory() }
    }
    
    // Callback for hotkey changes
    var hotkeyChanged: (() -> Void)?
    
    private let settingsKey = "PushToTranscribeSettings"
    private let historyKey = "PushToTranscribeHistory"
    private let maxHistoryCount = 100
    
    init() {
        // Load API key from Keychain before other settings
        apiKey = Self.loadFromKeychain() ?? ""
        loadSettings()
        loadTranscriptionHistory()
    }
    
    // MARK: - Keychain Helpers
    
    static func saveToKeychain(_ apiKey: String) {
        let data = apiKey.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccountAPIKey
        ]
        
        SecItemDelete(query as CFDictionary)
        
        if apiKey.isEmpty { return }
        
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("Keychain save failed: \(status)")
        }
    }
    
    static func loadFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccountAPIKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    // MARK: - Settings Persistence
    
    private func saveSettings() {
        let settings: [String: Any] = [
            "transcriptionModel": transcriptionModel,
            "language": language,
            "showNotifications": showNotifications,
            "copyToClipboard": copyToClipboard,
            "autoPaste": autoPaste,
            "hotkeyModifiers": hotkeyModifiers.rawValue,
            "hotkeyKeyCode": hotkeyKeyCode,
            // Cleanup hotkey settings
            "cleanupHotkeyEnabled": cleanupHotkeyEnabled,
            "cleanupHotkeyModifiers": cleanupHotkeyModifiers.rawValue,
            "cleanupHotkeyKeyCode": cleanupHotkeyKeyCode,
            "cleanupPrompt": cleanupPrompt,
            "cleanupModel": cleanupModel
        ]
        
        UserDefaults.standard.set(settings, forKey: settingsKey)
    }
    
    private func loadSettings() {
        guard let settings = UserDefaults.standard.dictionary(forKey: settingsKey) else {
            return
        }
        
        if let model = settings["transcriptionModel"] as? String {
            transcriptionModel = model
        }
        
        if let lang = settings["language"] as? String {
            language = lang
        }
        
        if let notifications = settings["showNotifications"] as? Bool {
            showNotifications = notifications
        }
        
        if let clipboard = settings["copyToClipboard"] as? Bool {
            copyToClipboard = clipboard
        }
        
        if let paste = settings["autoPaste"] as? Bool {
            autoPaste = paste
        }
        
        if let modifiers = settings["hotkeyModifiers"] as? UInt {
            hotkeyModifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        }
        
        if let keyCode = settings["hotkeyKeyCode"] as? UInt16 {
            hotkeyKeyCode = keyCode
        }
        
        // Cleanup hotkey settings
        if let cleanupEnabled = settings["cleanupHotkeyEnabled"] as? Bool {
            cleanupHotkeyEnabled = cleanupEnabled
        }
        
        if let cleanupModifiers = settings["cleanupHotkeyModifiers"] as? UInt {
            cleanupHotkeyModifiers = NSEvent.ModifierFlags(rawValue: cleanupModifiers)
        }
        
        if let cleanupKeyCode = settings["cleanupHotkeyKeyCode"] as? UInt16 {
            cleanupHotkeyKeyCode = cleanupKeyCode
        }
        
        // Load cleanup prompt: File first (survives reinstalls), then UserDefaults, then default
        if let filePrompt = loadCleanupPromptFromFile() {
            cleanupPrompt = filePrompt
        } else if let prompt = settings["cleanupPrompt"] as? String {
            cleanupPrompt = prompt
            // Migrate to file-based storage
            saveCleanupPromptToFile()
        }
        
        if let model = settings["cleanupModel"] as? String {
            cleanupModel = model
        }
    }
    
    // MARK: - Transcription History
    
    func addTranscription(_ text: String) {
        let entry = TranscriptionEntry(text: text)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.transcriptionHistory.insert(entry, at: 0)
            
            // Keep only the most recent entries
            if self.transcriptionHistory.count > self.maxHistoryCount {
                self.transcriptionHistory = Array(self.transcriptionHistory.prefix(self.maxHistoryCount))
            }
        }
    }
    
    func clearTranscriptionHistory() {
        DispatchQueue.main.async { [weak self] in
            self?.transcriptionHistory.removeAll()
        }
    }
    
    private func saveTranscriptionHistory() {
        do {
            let data = try JSONEncoder().encode(transcriptionHistory)
            UserDefaults.standard.set(data, forKey: historyKey)
        } catch {
            print("Failed to save transcription history: \(error)")
        }
    }
    
    private func loadTranscriptionHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else {
            return
        }
        
        do {
            let history = try JSONDecoder().decode([TranscriptionEntry].self, from: data)
            DispatchQueue.main.async { [weak self] in
                self?.transcriptionHistory = history
            }
        } catch {
            print("Failed to load transcription history: \(error)")
        }
    }
    
    // MARK: - Helper Methods
    
    func getHotkeyDescription() -> String {
        return formatHotkeyDescription(modifiers: hotkeyModifiers, keyCode: hotkeyKeyCode)
    }
    
    func getCleanupHotkeyDescription() -> String {
        return formatHotkeyDescription(modifiers: cleanupHotkeyModifiers, keyCode: cleanupHotkeyKeyCode)
    }
    
    private func formatHotkeyDescription(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) -> String {
        var parts: [String] = []
        
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        
        let keyName = keyCodeToString(keyCode)
        parts.append(keyName)
        
        return parts.joined(separator: " + ")
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 15: return "R"
        case 17: return "T"
        case 36: return "Enter"
        case 53: return "Escape"
        case 48: return "Tab"
        default: return "Key \(keyCode)"
        }
    }
    
    func exportHistory() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        
        var export = "MacWhisper Transcription History\n"
        export += "Exported: \(dateFormatter.string(from: Date()))\n"
        export += String(repeating: "=", count: 50) + "\n\n"
        
        for (index, entry) in transcriptionHistory.enumerated() {
            export += "[\(index + 1)] \(dateFormatter.string(from: entry.timestamp))\n"
            export += "\(entry.text)\n\n"
        }
        
        return export
    }
} 