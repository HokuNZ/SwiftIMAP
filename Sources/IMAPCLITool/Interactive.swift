import ArgumentParser
import Foundation
import SwiftIMAP

struct Interactive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start an interactive IMAP session"
    )
    
    @Option(name: .shortAndLong, help: "IMAP server hostname")
    var host: String
    
    @Option(name: .long, help: "IMAP server port")
    var port: Int = 993
    
    @Option(name: .shortAndLong, help: "Username for authentication")
    var username: String
    
    @Option(name: .shortAndLong, help: "Password for authentication")
    var password: String
    
    @ArgumentParser.Flag(name: .long, help: "Use STARTTLS instead of direct TLS")
    var starttls = false
    
    @ArgumentParser.Flag(name: .long, help: "Disable TLS (insecure)")
    var noTls = false
    
    @ArgumentParser.Flag(name: .shortAndLong, help: "Enable verbose logging")
    var verbose = false
    
    func run() async throws {
        let tlsMode: IMAPConfiguration.TLSMode
        if noTls {
            tlsMode = .disabled
        } else if starttls {
            tlsMode = .startTLS
        } else {
            tlsMode = .requireTLS
        }
        
        let config = IMAPConfiguration(
            hostname: host,
            port: port,
            tlsMode: tlsMode,
            authMethod: .login(username: username, password: password),
            logLevel: verbose ? .debug : .info
        )
        
        let client = IMAPClient(configuration: config)
        var currentMailbox: String?
        
        print("Connecting to \(host):\(port)...")
        
        do {
            try await client.connect()
            print("✓ Connected and authenticated successfully")
            print("\nType 'help' for available commands, 'quit' to exit")
            
            while true {
                print()
                if let mailbox = currentMailbox {
                    print("[\(mailbox)]> ", terminator: "")
                } else {
                    print("> ", terminator: "")
                }
                
                guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    continue
                }
                
                if input.isEmpty {
                    continue
                }
                
                let parts = input.split(separator: " ", maxSplits: 1).map(String.init)
                let command = parts[0].lowercased()
                let argument = parts.count > 1 ? parts[1] : nil
                
                do {
                    switch command {
                    case "help", "?":
                        printHelp()
                        
                    case "quit", "exit", "bye":
                        print("Disconnecting...")
                        await client.disconnect()
                        print("Goodbye!")
                        return
                        
                    case "list", "ls":
                        let pattern = argument ?? "*"
                        try await listMailboxes(client: client, pattern: pattern)
                        
                    case "select", "sel":
                        if let mailbox = argument {
                            try await selectMailbox(client: client, mailbox: mailbox)
                            currentMailbox = mailbox
                        } else {
                            print("Usage: select <mailbox>")
                        }
                        
                    case "status", "stat":
                        let mailbox = argument ?? currentMailbox ?? "INBOX"
                        try await showStatus(client: client, mailbox: mailbox)
                        
                    case "search":
                        if let mailbox = currentMailbox {
                            try await searchMessages(client: client, mailbox: mailbox)
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "messages", "msgs":
                        if let mailbox = currentMailbox {
                            try await listMessagesWithDetails(client: client, mailbox: mailbox)
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "fetch":
                        if let mailbox = currentMailbox {
                            if let uidStr = argument, let uid = UInt32(uidStr) {
                                try await fetchMessage(client: client, mailbox: mailbox, uid: uid)
                            } else {
                                print("Usage: fetch <uid>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "capability", "cap":
                        try await showCapabilities(client: client)
                        
                    case "close":
                        if currentMailbox != nil {
                            currentMailbox = nil
                            print("Mailbox closed")
                        } else {
                            print("No mailbox is currently selected")
                        }
                        
                    case "read", "markread":
                        if let mailbox = currentMailbox {
                            if let uidStr = argument, let uid = UInt32(uidStr) {
                                try await markAsRead(client: client, mailbox: mailbox, uid: uid)
                            } else {
                                print("Usage: read <uid>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "unread", "markunread":
                        if let mailbox = currentMailbox {
                            if let uidStr = argument, let uid = UInt32(uidStr) {
                                try await markAsUnread(client: client, mailbox: mailbox, uid: uid)
                            } else {
                                print("Usage: unread <uid>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "flag":
                        if let mailbox = currentMailbox {
                            if let uidStr = argument, let uid = UInt32(uidStr) {
                                try await flagMessage(client: client, mailbox: mailbox, uid: uid)
                            } else {
                                print("Usage: flag <uid>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "unflag":
                        if let mailbox = currentMailbox {
                            if let uidStr = argument, let uid = UInt32(uidStr) {
                                try await unflagMessage(client: client, mailbox: mailbox, uid: uid)
                            } else {
                                print("Usage: unflag <uid>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "copy":
                        if let mailbox = currentMailbox {
                            let args = argument?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
                            if args.count == 2, let uid = UInt32(args[0]) {
                                try await copyMessage(client: client, from: mailbox, uid: uid, to: args[1])
                            } else {
                                print("Usage: copy <uid> <destination_mailbox>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "move":
                        if let mailbox = currentMailbox {
                            let args = argument?.split(separator: " ", maxSplits: 1).map(String.init) ?? []
                            if args.count == 2, let uid = UInt32(args[0]) {
                                try await moveMessage(client: client, from: mailbox, uid: uid, to: args[1])
                            } else {
                                print("Usage: move <uid> <destination_mailbox>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "delete":
                        if let mailbox = currentMailbox {
                            if let uidStr = argument, let uid = UInt32(uidStr) {
                                try await deleteMessage(client: client, mailbox: mailbox, uid: uid)
                            } else {
                                print("Usage: delete <uid>")
                            }
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    case "expunge":
                        if let mailbox = currentMailbox {
                            try await expungeMailbox(client: client, mailbox: mailbox)
                        } else {
                            print("No mailbox selected. Use 'select <mailbox>' first")
                        }
                        
                    default:
                        print("Unknown command: \(command)")
                        print("Type 'help' for available commands")
                    }
                } catch {
                    print("Error: \(error)")
                }
            }
            
        } catch {
            print("Connection error: \(error)")
            await client.disconnect()
            throw ExitCode.failure
        }
    }
    
    private func printHelp() {
        print("""
        Available commands:
          help, ?               - Show this help message
          quit, exit, bye      - Disconnect and exit
          list [pattern]       - List mailboxes (default pattern: *)
          select <mailbox>     - Select a mailbox
          status [mailbox]     - Show mailbox status
          search               - Search messages in selected mailbox (shows sequence numbers)
          messages             - List messages with details (subject, from, date)
          fetch <uid>          - Fetch a message by UID
          capability           - Show server capabilities
          close                - Close selected mailbox
          
        Message manipulation commands (require mailbox selected):
          read <uid>           - Mark message as read
          unread <uid>         - Mark message as unread
          flag <uid>           - Flag message (star/important)
          unflag <uid>         - Remove flag from message
          copy <uid> <mailbox> - Copy message to another mailbox
          move <uid> <mailbox> - Move message to another mailbox
          delete <uid>         - Mark message for deletion
          expunge              - Permanently delete messages marked for deletion
        """)
    }
    
    private func listMailboxes(client: IMAPClient, pattern: String) async throws {
        print("Listing mailboxes with pattern '\(pattern)'...")
        let mailboxes = try await client.listMailboxes(reference: "", pattern: pattern)
        
        if mailboxes.isEmpty {
            print("No mailboxes found")
        } else {
            print("Found \(mailboxes.count) mailboxes:")
            for mailbox in mailboxes {
                let attrs = mailbox.attributes.isEmpty ? "" : " [\(mailbox.attributes.map { $0.rawValue }.joined(separator: " "))]"
                print("  • \(mailbox.name)\(attrs)")
            }
        }
    }
    
    private func selectMailbox(client: IMAPClient, mailbox: String) async throws {
        print("Selecting mailbox '\(mailbox)'...")
        let status = try await client.selectMailbox(mailbox)
        
        print("✓ Selected '\(mailbox)'")
        print("  Messages: \(status.messages)")
        print("  Recent: \(status.recent)")
        print("  Unseen: \(status.unseen)")
    }
    
    private func showStatus(client: IMAPClient, mailbox: String) async throws {
        print("Getting status for '\(mailbox)'...")
        let status = try await client.mailboxStatus(mailbox)
        
        print("Status of '\(mailbox)':")
        print("  Messages: \(status.messages)")
        print("  Recent: \(status.recent)")
        print("  Unseen: \(status.unseen)")
        print("  UID Next: \(status.uidNext)")
        print("  UID Validity: \(status.uidValidity)")
    }
    
    private func searchMessages(client: IMAPClient, mailbox: String) async throws {
        print("Searching all messages...")
        let messageNumbers = try await client.listMessages(in: mailbox)
        
        if messageNumbers.isEmpty {
            print("No messages found")
        } else {
            print("Found \(messageNumbers.count) messages")
            if messageNumbers.count <= 20 {
                print("Sequence numbers: \(messageNumbers.map(String.init).joined(separator: ", "))")
            } else {
                let preview = messageNumbers.prefix(20).map(String.init).joined(separator: ", ")
                print("Sequence numbers (first 20): \(preview)...")
            }
        }
    }
    
    private func fetchMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Fetching message UID \(uid)...")
        
        guard let summary = try await client.fetchMessage(uid: uid, in: mailbox) else {
            print("Message not found")
            return
        }
        
        print("\nMessage UID \(uid):")
        print("  Sequence: #\(summary.sequenceNumber)")
        print("  Date: \(formatDate(summary.internalDate))")
        print("  Size: \(formatBytes(summary.size))")
        print("  Flags: \(summary.flags.isEmpty ? "(none)" : summary.flags.map { $0.rawValue }.joined(separator: " "))")
        
        if let envelope = summary.envelope {
            print("\nEnvelope:")
            if let subject = envelope.subject {
                print("  Subject: \(subject)")
            }
            if !envelope.from.isEmpty {
                print("  From: \(envelope.from.map { $0.displayName }.joined(separator: ", "))")
            }
            if !envelope.to.isEmpty {
                print("  To: \(envelope.to.map { $0.displayName }.joined(separator: ", "))")
            }
            if let date = envelope.date {
                print("  Date: \(formatDate(date))")
            }
        }
        
        print("\nFetch body? (y/n): ", terminator: "")
        if let response = readLine()?.lowercased(), response == "y" {
            if let bodyData = try await client.fetchMessageBody(uid: uid, in: mailbox) {
                print("\nBody (\(formatBytes(UInt32(bodyData.count)))):")
                print(String(repeating: "=", count: 80))
                
                // Create a temporary MessageSummary to use the MIME parser
                let tempSummary = MessageSummary(
                    uid: uid,
                    sequenceNumber: summary.sequenceNumber,
                    flags: summary.flags,
                    internalDate: summary.internalDate,
                    size: summary.size,
                    envelope: summary.envelope
                )
                
                // Try to parse as MIME
                do {
                    if let mimeMessage = try tempSummary.parseMimeContent(from: bodyData) {
                        print("MIME Type: \(mimeMessage.contentType ?? "text/plain")")
                        if let charset = mimeMessage.charset {
                            print("Charset: \(charset)")
                        }
                        if let encoding = mimeMessage.transferEncoding {
                            print("Transfer Encoding: \(encoding)")
                        }
                        print("")
                        
                        // Show text content
                        if let plainText = mimeMessage.plainTextContent {
                            print("=== Plain Text Content ===")
                            print(plainText)
                        } else if let htmlContent = mimeMessage.htmlContent {
                            print("=== HTML Content ===")
                            print(htmlContent)
                        }
                        
                        // Show attachments if any
                        let attachments = mimeMessage.attachments
                        if !attachments.isEmpty {
                            print("\n=== Attachments ===")
                            for (index, attachment) in attachments.enumerated() {
                                let filename = attachment.filename ?? "attachment\(index + 1)"
                                let size = attachment.decodedData?.count ?? 0
                                print("  • \(filename) (\(formatBytes(UInt32(size))))")
                            }
                        }
                    } else {
                        // Fallback to raw display
                        if let bodyString = String(data: bodyData, encoding: .utf8) {
                            print(bodyString)
                        } else if let bodyString = String(data: bodyData, encoding: .ascii) {
                            print(bodyString)
                        } else {
                            print("(Unable to decode as UTF-8/ASCII)")
                        }
                    }
                } catch {
                    print("MIME parsing failed: \(error)")
                    print("\n=== Raw Content ===")
                    // Fallback to raw display
                    if let bodyString = String(data: bodyData, encoding: .utf8) {
                        print(bodyString)
                    } else if let bodyString = String(data: bodyData, encoding: .ascii) {
                        print(bodyString)
                    } else {
                        // Try to show as much as possible
                        print("(Unable to decode as UTF-8/ASCII, showing hex dump of first 500 bytes)")
                        let hexDump = bodyData.prefix(500).map { String(format: "%02x", $0) }.joined(separator: " ")
                        print(hexDump)
                    }
                }
                print(String(repeating: "=", count: 80))
            } else {
                print("Failed to fetch message body")
            }
        }
    }
    
    private func showCapabilities(client: IMAPClient) async throws {
        print("Getting server capabilities...")
        let capabilities = try await client.capability()
        
        print("Server capabilities:")
        let sorted = capabilities.sorted()
        for cap in sorted {
            print("  • \(cap)")
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
    
    private func formatBytes(_ bytes: UInt32) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func listMessagesWithDetails(client: IMAPClient, mailbox: String) async throws {
        print("Fetching message list...")
        
        // First, get the list of messages
        let messageNumbers = try await client.listMessages(in: mailbox)
        
        if messageNumbers.isEmpty {
            print("No messages found in \(mailbox)")
            return
        }
        
        print("Found \(messageNumbers.count) messages. Fetching details...")
        
        // For interactive mode, we can afford to fetch more details
        // But still limit to prevent overwhelming the display
        let limit = min(messageNumbers.count, 20)
        let messagesToShow = Array(messageNumbers.suffix(limit)) // Show most recent messages
        
        print("\nMessages in \(mailbox) (showing \(limit) most recent):")
        print(String(repeating: "=", count: 100))
        
        // Fetch details for each message
        var messages: [(seq: UInt32, summary: MessageSummary)] = []
        
        for seqNum in messagesToShow {
            if let summary = try await client.fetchMessageBySequence(sequenceNumber: seqNum, in: mailbox) {
                messages.append((seqNum, summary))
            }
        }
        
        // Display messages newest first
        for (seq, summary) in messages.reversed() {
            let fromAddr = summary.envelope?.from.first
            let from = fromAddr?.displayName ?? fromAddr?.emailAddress ?? "Unknown"
            let subject = summary.envelope?.subject ?? "(No subject)"
            let date = formatMessageDate(summary.internalDate)
            let size = formatBytes(summary.size)
            let flags = summary.flags.map { $0.rawValue }.joined(separator: " ")
            
            print("\n#\(seq) (UID: \(summary.uid))")
            print("  Date: \(date)")
            print("  From: \(from)")
            print("  Subject: \(subject)")
            print("  Size: \(size)")
            if !flags.isEmpty {
                print("  Flags: \(flags)")
            }
            
            // Debug: Check if envelope is nil
            if summary.envelope == nil {
                print("  [DEBUG: No envelope data received]")
            }
            
            print(String(repeating: "-", count: 100))
        }
        
        if messageNumbers.count > limit {
            print("\n(Showing \(limit) of \(messageNumbers.count) total messages)")
        }
    }
    
    private func formatMessageDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    // MARK: - Message Manipulation Commands
    
    private func markAsRead(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Marking message \(uid) as read...")
        try await client.markAsRead(uid: uid, in: mailbox)
        print("✓ Message marked as read")
    }
    
    private func markAsUnread(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Marking message \(uid) as unread...")
        try await client.markAsUnread(uid: uid, in: mailbox)
        print("✓ Message marked as unread")
    }
    
    private func flagMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Flagging message \(uid)...")
        try await client.storeFlags(uid: uid, in: mailbox, flags: [.flagged], action: .add)
        print("✓ Message flagged")
    }
    
    private func unflagMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Removing flag from message \(uid)...")
        try await client.storeFlags(uid: uid, in: mailbox, flags: [.flagged], action: .remove)
        print("✓ Flag removed")
    }
    
    private func copyMessage(client: IMAPClient, from sourceMailbox: String, uid: UID, to destinationMailbox: String) async throws {
        print("Copying message \(uid) from '\(sourceMailbox)' to '\(destinationMailbox)'...")
        try await client.copyMessage(uid: uid, from: sourceMailbox, to: destinationMailbox)
        print("✓ Message copied successfully")
    }
    
    private func moveMessage(client: IMAPClient, from sourceMailbox: String, uid: UID, to destinationMailbox: String) async throws {
        print("Moving message \(uid) from '\(sourceMailbox)' to '\(destinationMailbox)'...")
        try await client.moveMessage(uid: uid, from: sourceMailbox, to: destinationMailbox)
        print("✓ Message moved successfully")
    }
    
    private func deleteMessage(client: IMAPClient, mailbox: String, uid: UID) async throws {
        print("Marking message \(uid) for deletion...")
        try await client.markForDeletion(uid: uid, in: mailbox)
        print("✓ Message marked for deletion")
        print("  (Use 'expunge' to permanently delete)")
    }
    
    private func expungeMailbox(client: IMAPClient, mailbox: String) async throws {
        print("Expunging deleted messages from '\(mailbox)'...")
        try await client.expunge(mailbox: mailbox)
        print("✓ Deleted messages permanently removed")
    }
}