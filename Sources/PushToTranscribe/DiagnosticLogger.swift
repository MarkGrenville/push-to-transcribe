import Foundation
import Combine

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: LogLevel
    let category: String
    let message: String
    
    enum LogLevel: String {
        case info = "ℹ️"
        case success = "✅"
        case warning = "⚠️"
        case error = "❌"
        case debug = "🔍"
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
    
    var displayText: String {
        return "[\(formattedTime)] \(level.rawValue) [\(category)] \(message)"
    }
}

class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()
    
    @Published var logs: [LogEntry] = []
    @Published var isEnabled: Bool = true
    
    private let maxLogs = 500
    private let queue = DispatchQueue(label: "com.pushToTranscribe.logger", qos: .utility)
    
    private init() {}
    
    func log(_ message: String, level: LogEntry.LogLevel = .info, category: String = "General") {
        guard isEnabled else { return }
        
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        
        // Also print to console for debugging
        print(entry.displayText)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.logs.insert(entry, at: 0)
            
            // Trim old logs
            if self.logs.count > self.maxLogs {
                self.logs = Array(self.logs.prefix(self.maxLogs))
            }
        }
    }
    
    func info(_ message: String, category: String = "General") {
        log(message, level: .info, category: category)
    }
    
    func success(_ message: String, category: String = "General") {
        log(message, level: .success, category: category)
    }
    
    func warning(_ message: String, category: String = "General") {
        log(message, level: .warning, category: category)
    }
    
    func error(_ message: String, category: String = "General") {
        log(message, level: .error, category: category)
    }
    
    func debug(_ message: String, category: String = "General") {
        log(message, level: .debug, category: category)
    }
    
    func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.logs.removeAll()
        }
    }
    
    func exportLogs() -> String {
        var export = "Push to Transcribe - Diagnostic Logs\n"
        export += "Exported: \(Date())\n"
        export += String(repeating: "=", count: 60) + "\n\n"
        
        for entry in logs.reversed() {
            export += entry.displayText + "\n"
        }
        
        return export
    }
}
