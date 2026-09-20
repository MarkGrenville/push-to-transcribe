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
    
    /// Same content as `displayText` but with an absolute date, since a log file
    /// is read days after the fact and "HH:mm:ss" alone is ambiguous.
    var fileText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return "[\(formatter.string(from: timestamp))] \(level.rawValue) [\(category)] \(message)"
    }
}

class DiagnosticLogger: ObservableObject {
    static let shared = DiagnosticLogger()
    
    @Published var logs: [LogEntry] = []
    @Published var isEnabled: Bool = true
    
    private let maxLogs = 500
    private let queue = DispatchQueue(label: "com.pushToTranscribe.logger", qos: .utility)
    
    /// Persistent on-disk copy of every log line. The in-memory `logs` array is
    /// capped and dies with the process, which is useless for tracking down
    /// intermittent hotkey misses that show up hours apart.
    private(set) var logFileURL: URL?
    private var fileHandle: FileHandle?
    private let maxLogFileBytes: UInt64 = 5 * 1024 * 1024
    
    private init() {
        openLogFile()
    }
    
    private func openLogFile() {
        let fm = FileManager.default
        guard let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/PushToTranscribe", isDirectory: true) else { return }
        
        do {
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            let url = logs.appendingPathComponent("push-to-transcribe.log")
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            logFileURL = url
            fileHandle = handle
            
            let header = "\n\n===== Push to Transcribe launched \(Date()) (pid \(ProcessInfo.processInfo.processIdentifier)) =====\n"
            handle.write(Data(header.utf8))
        } catch {
            print("❌ Could not open diagnostic log file: \(error)")
        }
    }
    
    private func appendToFile(_ line: String) {
        guard let handle = fileHandle else { return }
        handle.write(Data((line + "\n").utf8))
        rotateIfNeeded()
    }
    
    private func rotateIfNeeded() {
        guard let url = logFileURL, let handle = fileHandle else { return }
        guard handle.offsetInFile > maxLogFileBytes else { return }
        
        let fm = FileManager.default
        let rolled = url.appendingPathExtension("1")
        handle.closeFile()
        fileHandle = nil
        try? fm.removeItem(at: rolled)
        try? fm.moveItem(at: url, to: rolled)
        fm.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }
    
    func log(_ message: String, level: LogEntry.LogLevel = .info, category: String = "General") {
        guard isEnabled else { return }
        
        let entry = LogEntry(timestamp: Date(), level: level, category: category, message: message)
        
        // Also print to console for debugging
        print(entry.displayText)
        
        queue.async { [weak self] in
            self?.appendToFile(entry.fileText)
        }
        
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
