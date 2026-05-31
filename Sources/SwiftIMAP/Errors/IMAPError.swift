import Foundation

public enum IMAPError: Error, LocalizedError {
    case connectionFailed(String, underlying: (any Error)?)
    case connectionError(String)
    case connectionClosed(IMAPServerResponse?)
    case authenticationFailed(String)
    case tlsError(String, underlying: (any Error)?)
    case protocolError(String)
    case parsingError(String)
    case commandFailed(IMAPServerResponse)
    case serverError(String)
    case timeout(command: String?)
    case disconnected
    case invalidState(String)
    case unsupportedCapability(String)
    case invalidArgument(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message, _):
            return "Connection failed: \(message)"
        case .connectionError(let message):
            return "Connection error: \(message)"
        case .connectionClosed(let response):
            if let response {
                return "Connection closed by server: \(response.line)"
            }
            return "Connection closed unexpectedly"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .tlsError(let message, _):
            return "TLS error: \(message)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        case .parsingError(let message):
            return "Parsing error: \(message)"
        case .commandFailed(let response):
            return "Command '\(response.commandName)' failed: \(response.line)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .timeout(let command):
            if let command {
                return "Operation '\(command)' timed out"
            }
            return "Operation timed out"
        case .disconnected:
            return "Connection disconnected"
        case .invalidState(let message):
            return "Invalid state: \(message)"
        case .unsupportedCapability(let capability):
            return "Unsupported capability: \(capability)"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        }
    }
}