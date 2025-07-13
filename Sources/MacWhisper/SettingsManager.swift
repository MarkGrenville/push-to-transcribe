import Foundation
import AppKit
import Combine

class SettingsManager: ObservableObject {
    // Published properties for UI binding
    @Published var transcriptionModel: String = "gpt-4o-transcribe" {
        didSet { saveSettings() }
    }
    
    @Published var language: String = "en" {
        didSet { saveSettings() }
    }
    
    @Published var showNotifications: Bool = true {
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
    
    @Published var transcriptionHistory: [TranscriptionEntry] = [] {
        didSet { saveTranscriptionHistory() }
    }
    
    // Callback for hotkey changes
    var hotkeyChanged: (() -> Void)?
    
    private let settingsKey = "MacWhisperSettings"
    private let historyKey = "MacWhisperHistory"
    private let maxHistoryCount = 100
    
    init() {
        loadSettings()
        loadTranscriptionHistory()
    }
    
    // MARK: - Settings Persistence
    
    private func saveSettings() {
        let settings: [String: Any] = [
            "transcriptionModel": transcriptionModel,
            "language": language,
            "showNotifications": showNotifications,
            "autoPaste": autoPaste,
            "hotkeyModifiers": hotkeyModifiers.rawValue,
            "hotkeyKeyCode": hotkeyKeyCode
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
        
        if let paste = settings["autoPaste"] as? Bool {
            autoPaste = paste
        }
        
        if let modifiers = settings["hotkeyModifiers"] as? UInt {
            hotkeyModifiers = NSEvent.ModifierFlags(rawValue: modifiers)
        }
        
        if let keyCode = settings["hotkeyKeyCode"] as? UInt16 {
            hotkeyKeyCode = keyCode
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
        var parts: [String] = []
        
        if hotkeyModifiers.contains(.control) { parts.append("Control") }
        if hotkeyModifiers.contains(.option) { parts.append("Option") }
        if hotkeyModifiers.contains(.command) { parts.append("Cmd") }
        if hotkeyModifiers.contains(.shift) { parts.append("Shift") }
        
        let keyName = keyCodeToString(hotkeyKeyCode)
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