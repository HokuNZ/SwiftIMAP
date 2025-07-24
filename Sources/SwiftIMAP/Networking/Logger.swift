import Foundation

protocol LoggerProtocol: Sendable {
    func log(level: IMAPConfiguration.LogLevel, _ message: String, file: String, function: String, line: Int)
}

extension LoggerProtocol {
    func log(level: IMAPConfiguration.LogLevel, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: level, message, file: file, function: function, line: line)
    }
    
    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .error, message, file: file, function: function, line: line)
    }
    
    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .warning, message, file: file, function: function, line: line)
    }
    
    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .info, message, file: file, function: function, line: line)
    }
    
    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .debug, message, file: file, function: function, line: line)
    }
    
    func trace(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .trace, message, file: file, function: function, line: line)
    }
}

final class Logger: LoggerProtocol, Sendable {
    let label: String
    let minimumLevel: IMAPConfiguration.LogLevel
    
    init(label: String, level: IMAPConfiguration.LogLevel) {
        self.label = label
        self.minimumLevel = level
    }
    
    func log(level: IMAPConfiguration.LogLevel, _ message: String, file: String, function: String, line: Int) {
        guard level <= minimumLevel else { return }
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let filename = URL(fileURLWithPath: file).lastPathComponent
        let levelString = levelDescription(for: level)
        
        print("[\(timestamp)] [\(levelString)] [\(label)] [\(filename):\(line)] \(message)")
    }
    
    private func levelDescription(for level: IMAPConfiguration.LogLevel) -> String {
        switch level {
        case .none:
            return "NONE"
        case .error:
            return "ERROR"
        case .warning:
            return "WARN"
        case .info:
            return "INFO"
        case .debug:
            return "DEBUG"
        case .trace:
            return "TRACE"
        }
    }
}

