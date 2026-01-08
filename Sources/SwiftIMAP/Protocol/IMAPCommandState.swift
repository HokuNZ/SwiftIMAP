import Foundation

enum IMAPSessionState: Sendable {
    case notAuthenticated
    case authenticated
    case selected(readOnly: Bool)
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
            if isReadOnly(state), requiresWriteAccess(command) {
                throw IMAPError.invalidState("\(command) not permitted in read-only mailbox")
            }
        }
    }

    private static func requireNotAuthenticated(_ state: IMAPSessionState, command: IMAPCommand.Command) throws {
        guard case .notAuthenticated = state else {
            throw IMAPError.invalidState("\(command) only permitted before authentication")
        }
    }

    private static func requireAuthenticated(_ state: IMAPSessionState, command: IMAPCommand.Command) throws {
        switch state {
        case .authenticated, .selected:
            return
        case .notAuthenticated:
            throw IMAPError.invalidState("\(command) requires authenticated state")
        }
    }

    private static func requireSelected(_ state: IMAPSessionState, command: IMAPCommand.Command) throws {
        guard case .selected = state else {
            throw IMAPError.invalidState("\(command) requires selected state")
        }
    }

    private static func isReadOnly(_ state: IMAPSessionState) -> Bool {
        if case .selected(let readOnly) = state {
            return readOnly
        }
        return false
    }

    private static func requiresWriteAccess(_ command: IMAPCommand.Command) -> Bool {
        switch command {
        case .store, .expunge, .move:
            return true
        case .uid(let uidCommand):
            return requiresWriteAccess(uidCommand)
        case .capability, .noop, .logout, .starttls, .authenticate, .login,
             .select, .examine, .create, .delete, .rename, .subscribe, .unsubscribe,
             .list, .lsub, .status, .append, .check, .close, .search, .fetch, .copy, .idle, .done:
            return false
        }
    }

    private static func requiresWriteAccess(_ command: IMAPCommand.UIDCommand) -> Bool {
        switch command {
        case .store, .expunge, .move:
            return true
        case .copy, .fetch, .search:
            return false
        }
    }
}
