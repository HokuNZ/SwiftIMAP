import Foundation

enum IMAPSessionState: Sendable {
    case notAuthenticated
    case authenticated
    case selected
}

struct IMAPCommandStateValidator {
    static func validate(command: IMAPCommand.Command, state: IMAPSessionState) throws {
        switch command {
        case .capability, .noop, .logout:
            return
        case .starttls, .authenticate, .login:
            try requireNotAuthenticated(state, command: command)
        case .select, .examine, .create, .delete, .rename, .subscribe, .unsubscribe, .list, .lsub, .status, .append:
            try requireAuthenticated(state, command: command)
        case .check, .close, .expunge, .search, .fetch, .store, .copy, .move, .uid, .idle, .done:
            try requireSelected(state, command: command)
        }
    }

    private static func requireNotAuthenticated(_ state: IMAPSessionState, command: IMAPCommand.Command) throws {
        guard state == .notAuthenticated else {
            throw IMAPError.invalidState("\(command) only permitted before authentication")
        }
    }

    private static func requireAuthenticated(_ state: IMAPSessionState, command: IMAPCommand.Command) throws {
        guard state == .authenticated || state == .selected else {
            throw IMAPError.invalidState("\(command) requires authenticated state")
        }
    }

    private static func requireSelected(_ state: IMAPSessionState, command: IMAPCommand.Command) throws {
        guard state == .selected else {
            throw IMAPError.invalidState("\(command) requires selected state")
        }
    }
}
