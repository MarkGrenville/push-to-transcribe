import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settingsManager: settingsManager)
                .tabItem {
                    Image(systemName: "gear")
                    Text("General")
                }
                .tag(0)
            
            HotkeySettingsView(settingsManager: settingsManager)
                .tabItem {
                    Image(systemName: "keyboard")
                    Text("Hotkeys")
                }
                .tag(1)
            
            TranscriptionHistoryView(settingsManager: settingsManager)
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("History")
                }
                .tag(2)
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General Settings")
                .font(.title2)
                .bold()
            
            GroupBox(label: Text("Transcription Model")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model:", selection: $settingsManager.transcriptionModel) {
                        Text("GPT-4o Mini Transcribe (Fastest) ⚡").tag("gpt-4o-mini-transcribe")
                        Text("GPT-4o Transcribe (Best Quality) 🎯").tag("gpt-4o-transcribe")
                        Text("Whisper-1 (Legacy)").tag("whisper-1")
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    
                    Text("GPT-4o Mini is the fastest option. GPT-4o offers best accuracy. Whisper-1 is the original model.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
            }
            
            GroupBox(label: Text("Language")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Language:", selection: $settingsManager.language) {
                        Text("Auto-detect").tag("auto")
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Italian").tag("it")
                        Text("Portuguese").tag("pt")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                    }
                    .pickerStyle(MenuPickerStyle())
                }
                .padding(10)
            }
            
            Toggle("Copy to clipboard", isOn: $settingsManager.copyToClipboard)
            Toggle("Auto-paste transcriptions", isOn: $settingsManager.autoPaste)
                .disabled(!settingsManager.copyToClipboard)
            Toggle("Show notifications", isOn: $settingsManager.showNotifications)
            
            Spacer()
        }
        .padding(20)
    }
}

struct HotkeySettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var isRecordingHotkey = false
    @State private var hotkeyDisplay = "Control + Space"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Hotkey Settings")
                .font(.title2)
                .bold()
            
            GroupBox(label: Text("Recording Hotkey")) {
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Text("Current hotkey:")
                        Spacer()
                        Text(hotkeyDisplay)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(5)
                    }
                    
                    Button(action: {
                        isRecordingHotkey.toggle()
                    }) {
                        Text(isRecordingHotkey ? "Press new hotkey..." : "Change Hotkey")
                            .foregroundColor(isRecordingHotkey ? .red : .blue)
                    }
                    .disabled(isRecordingHotkey)
                    
                    if isRecordingHotkey {
                        Text("Press the key combination you want to use for recording")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Popular combinations:")
                            .font(.caption)
                            .bold()
                        
                        HStack {
                            Button("Control + Space") {
                                setHotkey(modifiers: .control, keyCode: 49)
                            }
                            .buttonStyle(LinkButtonStyle())
                            
                            Button("Option + Space") {
                                setHotkey(modifiers: .option, keyCode: 49)
                            }
                            .buttonStyle(LinkButtonStyle())
                            
                            Button("Cmd + Shift + R") {
                                setHotkey(modifiers: [.command, .shift], keyCode: 15)
                            }
                            .buttonStyle(LinkButtonStyle())
                        }
                        .font(.caption)
                    }
                }
                .padding(10)
            }
            
            Text("⚠️ Make sure your chosen hotkey doesn't conflict with other apps")
                .font(.caption)
                .foregroundColor(.orange)
            
            Spacer()
        }
        .padding(20)
        .onAppear {
            updateHotkeyDisplay()
        }
    }
    
    private func setHotkey(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
        settingsManager.hotkeyModifiers = modifiers
        settingsManager.hotkeyKeyCode = keyCode
        updateHotkeyDisplay()
    }
    
    private func updateHotkeyDisplay() {
        let modifiers = settingsManager.hotkeyModifiers
        var parts: [String] = []
        
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.command) { parts.append("Cmd") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        
        let keyName = keyCodeToString(settingsManager.hotkeyKeyCode)
        parts.append(keyName)
        
        hotkeyDisplay = parts.joined(separator: " + ")
    }
    
    private func keyCodeToString(_ keyCode: UInt16) -> String {
        switch keyCode {
        case 49: return "Space"
        case 15: return "R"
        case 17: return "T"
        default: return "Key \(keyCode)"
        }
    }
}

struct TranscriptionHistoryView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var searchText = ""
    
    var filteredTranscriptions: [TranscriptionEntry] {
        if searchText.isEmpty {
            return settingsManager.transcriptionHistory
        } else {
            return settingsManager.transcriptionHistory.filter { 
                $0.text.localizedCaseInsensitiveContains(searchText) 
            }
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Transcription History")
                .font(.title2)
                .bold()
            
            HStack {
                TextField("Search transcriptions...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                
                Button("Clear All") {
                    settingsManager.clearTranscriptionHistory()
                }
                .foregroundColor(.red)
            }
            
            List {
                ForEach(filteredTranscriptions) { entry in
                    TranscriptionRowView(entry: entry, onCopy: { text in
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    })
                }
            }
            .listStyle(PlainListStyle())
        }
        .padding(20)
    }
}

struct TranscriptionRowView: View {
    let entry: TranscriptionEntry
    let onCopy: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Button("Copy") {
                    onCopy(entry.text)
                }
                .buttonStyle(BorderlessButtonStyle())
                .font(.caption)
            }
            
            Text(entry.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }
}

struct TranscriptionEntry: Identifiable, Codable {
    let id: UUID
    let text: String
    let timestamp: Date
    
    init(text: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = Date()
    }
} 