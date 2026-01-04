import Foundation
import SwiftIMAP

extension Interactive {
    func runSession(client: IMAPClient) async {
        var currentMailbox: String?

        while true {
            guard let input = readInput(currentMailbox: currentMailbox) else {
                continue
            }

            if input.isEmpty {
                continue
            }

            let parsed = parseCommand(input)

            do {
                let result = try await handleCommand(parsed, client: client, currentMailbox: currentMailbox)
                switch result {
                case .continueSession(let mailbox):
                    currentMailbox = mailbox
                case .exit:
                    return
                }
            } catch {
                print("Error: \(error)")
            }
        }
    }

    private struct ParsedCommand {
        let command: String
        let argument: String?
    }

    private enum CommandResult {
        case continueSession(String?)
        case exit
    }

    private func readInput(currentMailbox: String?) -> String? {
        print()
        if let mailbox = currentMailbox {
            print("[\(mailbox)]> ", terminator: "")
        } else {
            print("> ", terminator: "")
        }

        guard let line = readLine() else {
            return nil
        }

        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseCommand(_ input: String) -> ParsedCommand {
        let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
        let command = parts[0].lowercased()
        let argument = parts.count > 1 ? parts[1] : nil
        return ParsedCommand(command: command, argument: argument)
    }

    private func handleCommand(
        _ parsed: ParsedCommand,
        client: IMAPClient,
        currentMailbox: String?
    ) async throws -> CommandResult {
        if let result = try await handleSessionCommand(parsed, client: client, currentMailbox: currentMailbox) {
            return result
        }
        if let result = try await handleMailboxCommand(parsed, client: client, currentMailbox: currentMailbox) {
            return result
        }
        if let result = try await handleSearchCommand(parsed, client: client, currentMailbox: currentMailbox) {
            return result
        }
        if let result = try await handleMessageCommand(parsed, client: client, currentMailbox: currentMailbox) {
            return result
        }

        print("Unknown command: \(parsed.command)")
        print("Type 'help' for available commands")
        return .continueSession(currentMailbox)
    }

    private func handleSessionCommand(
        _ parsed: ParsedCommand,
        client: IMAPClient,
        currentMailbox: String?
    ) async throws -> CommandResult? {
        switch parsed.command {
        case "help", "?":
            printHelp()
            return .continueSession(currentMailbox)

        case "quit", "exit", "bye":
            print("Disconnecting...")
            await client.disconnect()
            print("Goodbye!")
            return .exit

        case "capability", "cap":
            try await showCapabilities(client: client)
            return .continueSession(currentMailbox)

        default:
            return nil
        }
    }

    private func handleMailboxCommand(
        _ parsed: ParsedCommand,
        client: IMAPClient,
        currentMailbox: String?
    ) async throws -> CommandResult? {
        switch parsed.command {
        case "list", "ls":
            let pattern = parsed.argument ?? "*"
            try await listMailboxes(client: client, pattern: pattern)
            return .continueSession(currentMailbox)

        case "select", "sel":
            guard let mailbox = parsed.argument else {
                print("Usage: select <mailbox>")
                return .continueSession(currentMailbox)
            }
            try await selectMailbox(client: client, mailbox: mailbox)
            return .continueSession(mailbox)

        case "status", "stat":
            let mailbox = parsed.argument ?? currentMailbox ?? "INBOX"
            try await showStatus(client: client, mailbox: mailbox)
            return .continueSession(currentMailbox)

        case "close":
            if currentMailbox != nil {
                print("Mailbox closed")
                return .continueSession(nil)
            }
            print("No mailbox is currently selected")
            return .continueSession(currentMailbox)

        default:
            return nil
        }
    }

    private func handleSearchCommand(
        _ parsed: ParsedCommand,
        client: IMAPClient,
        currentMailbox: String?
    ) async throws -> CommandResult? {
        guard parsed.command == "search" else {
            return nil
        }

        guard let mailbox = requireMailbox(currentMailbox) else {
            return .continueSession(currentMailbox)
        }

        try await searchMessages(client: client, mailbox: mailbox, criteria: parsed.argument)
        return .continueSession(currentMailbox)
    }

    private func handleMessageCommand(
        _ parsed: ParsedCommand,
        client: IMAPClient,
        currentMailbox: String?
    ) async throws -> CommandResult? {
        switch parsed.command {
        case "messages", "msgs":
            guard let mailbox = requireMailbox(currentMailbox) else {
                return .continueSession(currentMailbox)
            }
            try await listMessagesWithDetails(client: client, mailbox: mailbox)
            return .continueSession(currentMailbox)

        case "fetch":
            guard let mailbox = requireMailbox(currentMailbox) else {
                return .continueSession(currentMailbox)
            }
            guard let uid = parseUID(parsed.argument, usage: "Usage: fetch <uid>") else {
                return .continueSession(currentMailbox)
            }
            try await fetchMessage(client: client, mailbox: mailbox, uid: uid)
            return .continueSession(currentMailbox)

        case "read", "markread":
            return try await handleFlagCommand(
                client: client,
                mailbox: currentMailbox,
                argument: parsed.argument,
                usage: "Usage: read <uid>",
                action: markAsRead
            )

        case "unread", "markunread":
            return try await handleFlagCommand(
                client: client,
                mailbox: currentMailbox,
                argument: parsed.argument,
                usage: "Usage: unread <uid>",
                action: markAsUnread
            )

        case "flag":
            return try await handleFlagCommand(
                client: client,
                mailbox: currentMailbox,
                argument: parsed.argument,
                usage: "Usage: flag <uid>",
                action: flagMessage
            )

        case "unflag":
            return try await handleFlagCommand(
                client: client,
                mailbox: currentMailbox,
                argument: parsed.argument,
                usage: "Usage: unflag <uid>",
                action: unflagMessage
            )

        case "copy":
            guard let mailbox = requireMailbox(currentMailbox) else {
                return .continueSession(currentMailbox)
            }
            guard let parsedArgs = parseUIDAndMailbox(parsed.argument, usage: "Usage: copy <uid> <destination_mailbox>") else {
                return .continueSession(currentMailbox)
            }
            try await copyMessage(client: client, from: mailbox, uid: parsedArgs.uid, to: parsedArgs.destination)
            return .continueSession(currentMailbox)

        case "move":
            guard let mailbox = requireMailbox(currentMailbox) else {
                return .continueSession(currentMailbox)
            }
            guard let parsedArgs = parseUIDAndMailbox(parsed.argument, usage: "Usage: move <uid> <destination_mailbox>") else {
                return .continueSession(currentMailbox)
            }
            try await moveMessage(client: client, from: mailbox, uid: parsedArgs.uid, to: parsedArgs.destination)
            return .continueSession(currentMailbox)

        case "delete":
            return try await handleFlagCommand(
                client: client,
                mailbox: currentMailbox,
                argument: parsed.argument,
                usage: "Usage: delete <uid>",
                action: deleteMessage
            )

        case "expunge":
            guard let mailbox = requireMailbox(currentMailbox) else {
                return .continueSession(currentMailbox)
            }
            try await expungeMailbox(client: client, mailbox: mailbox)
            return .continueSession(currentMailbox)

        default:
            return nil
        }
    }

    private func handleFlagCommand(
        client: IMAPClient,
        mailbox currentMailbox: String?,
        argument: String?,
        usage: String,
        action: (IMAPClient, String, UID) async throws -> Void
    ) async throws -> CommandResult {
        guard let mailbox = requireMailbox(currentMailbox) else {
            return .continueSession(currentMailbox)
        }
        guard let uid = parseUID(argument, usage: usage) else {
            return .continueSession(currentMailbox)
        }
        try await action(client, mailbox, uid)
        return .continueSession(currentMailbox)
    }

    private func requireMailbox(_ mailbox: String?) -> String? {
        guard let mailbox = mailbox else {
            print("No mailbox selected. Use 'select <mailbox>' first")
            return nil
        }
        return mailbox
    }

    private func parseUID(_ argument: String?, usage: String) -> UID? {
        guard let argument = argument, let uid = UInt32(argument) else {
            print(usage)
            return nil
        }
        return uid
    }

    private struct UIDAndMailbox {
        let uid: UID
        let destination: String
    }

    private func parseUIDAndMailbox(_ argument: String?, usage: String) -> UIDAndMailbox? {
        guard let argument = argument else {
            print(usage)
            return nil
        }

        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, let uid = UInt32(parts[0]) else {
            print(usage)
            return nil
        }

        return UIDAndMailbox(uid: uid, destination: parts[1])
    }
}
