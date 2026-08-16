import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var selectedTab = 0
    var onCleanupText: ((String, @escaping (String) -> Void) -> Void)?
    
    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(settingsManager: settingsManager)
                .tabItem {
                    Image(systemName: "gear")
                    Text("General")
                }
                .tag(0)
            
            APIKeySettingsView(settingsManager: settingsManager)
                .tabItem {
                    Image(systemName: "key")
                    Text("API Key")
                }
                .tag(1)
            
            HotkeySettingsView(settingsManager: settingsManager)
                .tabItem {
                    Image(systemName: "keyboard")
                    Text("Hotkeys")
                }
                .tag(2)
            
            TranscriptionHistoryView(settingsManager: settingsManager, onCleanupText: onCleanupText)
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("History")
                }
                .tag(3)
            
            DiagnosticsView()
                .tabItem {
                    Image(systemName: "stethoscope")
                    Text("Diagnostics")
                }
                .tag(4)
        }
        .frame(width: 600, height: 450)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var archiveStats = SettingsManager.ArchiveStats()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("General Settings")
                .font(.title2)
                .bold()
            
            GroupBox(label: Text("Voice Archive")) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "waveform")
                                .foregroundColor(.blue)
                            Text("\(archiveStats.audioFileCount) recordings")
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.green)
                            Text("\(archiveStats.transcriptionFileCount) transcriptions")
                        }
                    }
                    .font(.system(.body))
                    
                    Divider()
                        .frame(height: 30)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(archiveStats.formattedSize)
                            .font(.system(.title3, design: .rounded).bold())
                        Text("disk usage")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Reveal in Finder") {
                        if let dir = SettingsManager.appSupportDirectory {
                            let archiveDir = dir.appendingPathComponent("voice-archive")
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: archiveDir.path)
                        }
                    }
                    .font(.caption)
                }
                .padding(10)
            }
            
            GroupBox(label: Text("Transcription Model")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Model:", selection: $settingsManager.transcriptionModel) {
                        Text("GPT Transcribe (Latest, Best Quality) 🎯").tag("gpt-transcribe")
                        Text("GPT-4o Mini Transcribe (Fast) ⚡").tag("gpt-4o-mini-transcribe")
                        Text("GPT-4o Transcribe").tag("gpt-4o-transcribe")
                        Text("Whisper-1 (Legacy)").tag("whisper-1")
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    
                    Text("GPT Transcribe is the latest model with best accuracy across accents, languages, and noisy audio. GPT-4o Mini is faster but less accurate.")
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
        .onAppear {
            archiveStats = settingsManager.getArchiveStats()
        }
    }
}

struct APIKeySettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var keyInput: String = ""
    @State private var isRevealed: Bool = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("OpenAI API Key")
                .font(.title2)
                .bold()
            
            GroupBox(label: Text("API Key")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your API key is stored securely in the macOS Keychain and never saved to disk.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack {
                        if isRevealed {
                            TextField("sk-proj-...", text: $keyInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(.body, design: .monospaced))
                        } else {
                            SecureField("sk-proj-...", text: $keyInput)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .font(.system(.body, design: .monospaced))
                        }
                        
                        Button(action: { isRevealed.toggle() }) {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(BorderlessButtonStyle())
                    }
                    
                    HStack {
                        Button("Save Key") {
                            settingsManager.apiKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        
                        if settingsManager.hasValidAPIKey {
                            Button("Clear Key") {
                                keyInput = ""
                                settingsManager.apiKey = ""
                            }
                            .foregroundColor(.red)
                        }
                        
                        Spacer()
                        
                        if settingsManager.hasValidAPIKey {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Key configured")
                                    .foregroundColor(.green)
                            }
                            .font(.caption)
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("No API key set")
                                    .foregroundColor(.orange)
                            }
                            .font(.caption)
                        }
                    }
                }
                .padding(10)
            }
            
            GroupBox(label: Text("How to get an API key")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Go to platform.openai.com")
                    Text("2. Sign in or create an account")
                    Text("3. Navigate to API Keys")
                    Text("4. Create a new secret key and paste it above")
                }
                .font(.caption)
                .padding(10)
            }
            
            Spacer()
        }
        .padding(20)
        .onAppear {
            keyInput = settingsManager.apiKey
        }
    }
}

struct HotkeySettingsView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var hotkeyDisplay = "Control + Space"
    @State private var cleanupHotkeyDisplay = "Option + Space"
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("Hotkey Settings")
                    .font(.title2)
                    .bold()
                
                // Primary Hotkey
                GroupBox(label: Text("Primary Hotkey (Transcribe Only)")) {
                    VStack(alignment: .leading, spacing: 10) {
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
                        
                        HStack(spacing: 8) {
                            Text("Quick set:")
                                .font(.caption)
                            Button("Caps Lock") {
                                setPrimaryHotkey(modifiers: [], keyCode: SettingsManager.capsLockKeyCode)
                            }
                            .buttonStyle(LinkButtonStyle())
                            .font(.caption)
                            
                            Button("Ctrl+Space") {
                                setPrimaryHotkey(modifiers: .control, keyCode: 49)
                            }
                            .buttonStyle(LinkButtonStyle())
                            .font(.caption)
                            
                            Button("Cmd+Shift+R") {
                                setPrimaryHotkey(modifiers: [.command, .shift], keyCode: 15)
                            }
                            .buttonStyle(LinkButtonStyle())
                            .font(.caption)
                        }
                        
                        if settingsManager.isPrimaryCapsLock {
                            Text("While this app is running, Caps Lock is remapped so the light and on-screen indicator stay off. Hold Caps Lock to transcribe; Option + Caps Lock to clean up. Quitting the app restores normal Caps Lock.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(8)
                }
                
                // Cleanup Hotkey
                GroupBox(label: Text("Cleanup Hotkey (Transcribe + Clean with AI)")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Enable cleanup hotkey", isOn: $settingsManager.cleanupHotkeyEnabled)
                        
                        if settingsManager.cleanupHotkeyEnabled {
                            HStack {
                                Text("Current hotkey:")
                                Spacer()
                                Text(cleanupHotkeyDisplay)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(5)
                            }
                            
                            HStack(spacing: 8) {
                                Text("Quick set:")
                                    .font(.caption)
                                Button("Opt+Space") {
                                    setCleanupHotkey(modifiers: .option, keyCode: 49)
                                }
                                .buttonStyle(LinkButtonStyle())
                                .font(.caption)
                                
                                Button("Cmd+Shift+T") {
                                    setCleanupHotkey(modifiers: [.command, .shift], keyCode: 17)
                                }
                                .buttonStyle(LinkButtonStyle())
                                .font(.caption)
                            }
                            
                            Divider()
                            
                            // Cleanup Model
                            Picker("Cleanup Model:", selection: $settingsManager.cleanupModel) {
                                Text("GPT-4o Mini (Fast)").tag("gpt-4o-mini")
                                Text("GPT-4o (Best)").tag("gpt-4o")
                                Text("GPT-4 Turbo").tag("gpt-4-turbo")
                            }
                            .pickerStyle(MenuPickerStyle())
                            
                            // Cleanup Prompt
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("Cleanup Prompt:")
                                        .font(.caption)
                                        .bold()
                                    Spacer()
                                    Button("Reset") {
                                        settingsManager.cleanupPrompt = SettingsManager.defaultCleanupPrompt
                                    }
                                    .font(.caption)
                                    .buttonStyle(LinkButtonStyle())
                                }
                                
                                TextEditor(text: $settingsManager.cleanupPrompt)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(height: 80)
                                    .border(Color.gray.opacity(0.3), width: 1)
                            }
                            
                            Text("The AI will use this prompt to clean up your transcribed text before pasting.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                }
                
                Text("⚠️ Make sure your hotkeys don't conflict with other apps")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            .padding(20)
        }
        .onAppear {
            updateHotkeyDisplays()
        }
    }
    
    private func setPrimaryHotkey(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
        settingsManager.hotkeyModifiers = modifiers
        settingsManager.hotkeyKeyCode = keyCode
        updateHotkeyDisplays()
    }
    
    private func setCleanupHotkey(modifiers: NSEvent.ModifierFlags, keyCode: UInt16) {
        settingsManager.cleanupHotkeyModifiers = modifiers
        settingsManager.cleanupHotkeyKeyCode = keyCode
        updateHotkeyDisplays()
    }
    
    private func updateHotkeyDisplays() {
        hotkeyDisplay = settingsManager.getHotkeyDescription()
        cleanupHotkeyDisplay = settingsManager.getCleanupHotkeyDescription()
    }
}

struct TranscriptionHistoryView: View {
    @ObservedObject var settingsManager: SettingsManager
    @State private var searchText = ""
    @State private var cleaningEntryId: UUID? = nil
    var onCleanupText: ((String, @escaping (String) -> Void) -> Void)?
    
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
                    TranscriptionRowView(
                        entry: entry,
                        isCleaningUp: cleaningEntryId == entry.id,
                        onCopy: { text in
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        },
                        onCleanup: onCleanupText != nil ? { text in
                            cleanupEntry(entry, text: text)
                        } : nil
                    )
                }
            }
            .listStyle(PlainListStyle())
        }
        .padding(20)
    }
    
    private func cleanupEntry(_ entry: TranscriptionEntry, text: String) {
        guard let onCleanupText = onCleanupText else { return }
        
        cleaningEntryId = entry.id
        
        onCleanupText(text) { cleanedText in
            DispatchQueue.main.async {
                // Add the cleaned text as a new entry at the top
                settingsManager.addTranscription(cleanedText)
                
                // Copy to clipboard
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cleanedText, forType: .string)
                
                cleaningEntryId = nil
            }
        }
    }
}

struct TranscriptionRowView: View {
    let entry: TranscriptionEntry
    var isCleaningUp: Bool = false
    let onCopy: (String) -> Void
    var onCleanup: ((String) -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                if let onCleanup = onCleanup {
                    if isCleaningUp {
                        HStack(spacing: 4) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Cleaning...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Clean up") {
                            onCleanup(entry.text)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .font(.caption)
                        .foregroundColor(.blue)
                    }
                }
                
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

struct DiagnosticsView: View {
    @ObservedObject var logger = DiagnosticLogger.shared
    @State private var filterText = ""
    @State private var selectedLevel: LogEntry.LogLevel? = nil
    
    var filteredLogs: [LogEntry] {
        var logs = logger.logs
        
        if let level = selectedLevel {
            logs = logs.filter { $0.level == level }
        }
        
        if !filterText.isEmpty {
            logs = logs.filter { 
                $0.message.localizedCaseInsensitiveContains(filterText) ||
                $0.category.localizedCaseInsensitiveContains(filterText)
            }
        }
        
        return logs
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Diagnostics")
                    .font(.title2)
                    .bold()
                
                Spacer()
                
                // Log count indicator
                Text("\(logger.logs.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Filter controls
            HStack(spacing: 10) {
                TextField("Filter logs...", text: $filterText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .frame(maxWidth: 200)
                
                Picker("Level", selection: $selectedLevel) {
                    Text("All").tag(nil as LogEntry.LogLevel?)
                    Text("ℹ️ Info").tag(LogEntry.LogLevel.info as LogEntry.LogLevel?)
                    Text("✅ Success").tag(LogEntry.LogLevel.success as LogEntry.LogLevel?)
                    Text("⚠️ Warning").tag(LogEntry.LogLevel.warning as LogEntry.LogLevel?)
                    Text("❌ Error").tag(LogEntry.LogLevel.error as LogEntry.LogLevel?)
                    Text("🔍 Debug").tag(LogEntry.LogLevel.debug as LogEntry.LogLevel?)
                }
                .pickerStyle(MenuPickerStyle())
                .frame(width: 120)
                
                Spacer()
                
                Toggle("Logging", isOn: $logger.isEnabled)
                    .toggleStyle(SwitchToggleStyle())
                
                Button("Clear") {
                    logger.clear()
                }
                .foregroundColor(.red)
                
                Button("Export") {
                    exportLogs()
                }
            }
            
            // Log list
            if filteredLogs.isEmpty {
                VStack {
                    Spacer()
                    Text("No logs yet")
                        .foregroundColor(.secondary)
                    Text("Try recording something to see API activity")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredLogs) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 5)
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(5)
            }
            
            // Quick info
            HStack {
                Text("💡 Tip: Look for ❌ errors or ⚠️ warnings if transcription is failing")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(20)
    }
    
    private func exportLogs() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.text]
        savePanel.nameFieldStringValue = "diagnostic-logs.txt"
        
        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try logger.exportLogs().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to export logs: \(error)")
            }
        }
    }
}

struct LogEntryRow: View {
    let entry: LogEntry
    
    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(entry.formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 85, alignment: .leading)
            
            Text(entry.level.rawValue)
                .frame(width: 20)
            
            Text("[\(entry.category)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(categoryColor(entry.category))
                .frame(width: 90, alignment: .leading)
            
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(levelColor(entry.level))
                .lineLimit(3)
            
            Spacer()
        }
        .padding(.vertical, 2)
        .background(backgroundColor(entry.level).opacity(0.1))
        .cornerRadius(2)
    }
    
    private func levelColor(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        case .debug: return .gray
        }
    }
    
    private func backgroundColor(_ level: LogEntry.LogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        default: return .clear
        }
    }
    
    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "API": return .blue
        case "Audio": return .purple
        case "Transcription": return .green
        default: return .secondary
        }
    }
} 