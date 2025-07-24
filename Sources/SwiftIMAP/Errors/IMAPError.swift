import Foundation

public enum IMAPError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionError(String)
    case connectionClosed
    case authenticationFailed(String)
    case tlsError(String)
    case protocolError(String)
    case parsingError(String)
    case commandFailed(command: String, response: String)
    case serverError(String)
    case timeout
    case disconnected
    case invalidState(String)
    case unsupportedCapability(String)
    case mailboxNotFound(String)
    case messageNotFound(uid: UInt32)
    case quotaExceeded
    case permissionDenied
    case invalidArgument(String)
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .connectionError(let message):
            return "Connection error: \(message)"
        case .connectionClosed:
            return "Connection closed unexpectedly"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .tlsError(let message):
            return "TLS error: \(message)"
        case .protocolError(let message):
            return "Protocol error: \(message)"
        case .parsingError(let message):
            return "Parsing error: \(message)"
        case .commandFailed(let command, let response):
            return "Command '\(command)' failed: \(response)"
        case .serverError(let message):
            return "Server error: \(message)"
        case .timeout:
            return "Operation timed out"
        case .disconnected:
            return "Connection disconnected"
        case .invalidState(let message):
            return "Invalid state: \(message)"
        case .unsupportedCapability(let capability):
            return "Unsupported capability: \(capability)"
        case .mailboxNotFound(let name):
            return "Mailbox not found: \(name)"
        case .messageNotFound(let uid):
            return "Message not found: UID \(uid)"
        case .quotaExceeded:
            return "Quota exceeded"
        case .permissionDenied:
            return "Permission denied"
        case .invalidArgument(let message):
            return "Invalid argument: \(message)"
        }
    }
}