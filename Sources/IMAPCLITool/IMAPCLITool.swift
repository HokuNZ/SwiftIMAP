import ArgumentParser
import Foundation
import SwiftIMAP

@main
struct IMAPCLITool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-imap-tester",
        abstract: "A command-line tool for testing IMAP connections",
        version: "0.1.0",
        subcommands: [Connect.self, Interactive.self]
    )
}

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Connect to an IMAP server and perform operations"
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
    
    @Option(name: .long, help: "Command to execute (list, select, search, fetch)")
    var command: String = "list"
    
    @Option(name: .long, help: "Mailbox name for select/search/fetch commands")
    var mailbox: String = "INBOX"
    
    @Option(name: .long, help: "Message UID for fetch command")
    var uid: UInt32?
    
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
        
        print("Connecting to \(host):\(port)...")
        
        do {
            try await client.connect()
            print("✓ Connected and authenticated successfully")
            
            switch command.lowercased() {
            case "list":
                try await listMailboxes(client: client)
                
            case "select":
                try await selectMailbox(client: client)
                
            case "search":
                try await searchMessages(client: client)
                
            case "fetch":
                if let uid = uid {
                    try await fetchMessage(client: client, uid: uid)
                } else {
                    print("Error: --uid is required for fetch command")
                }
                
            default:
                print("Unknown command: \(command)")
                print("Available commands: list, select, search, fetch")
            }
            
            await client.disconnect()
            print("✓ Disconnected")
            
        } catch {
            print("Error: \(error)")
            await client.disconnect()
            throw ExitCode.failure
        }
    }
    
    private func listMailboxes(client: IMAPClient) async throws {
        print("\nListing mailboxes...")
        let mailboxes = try await client.listMailboxes()
        
        if mailboxes.isEmpty {
            print("No mailboxes found")
            print("(This might be a bug - trying with verbose logging)")
        } else {
            print("Found \(mailboxes.count) mailboxes:")
            for mailbox in mailboxes {
                let attrs = mailbox.attributes.map { $0.rawValue }.joined(separator: " ")
                let delimiter = mailbox.delimiter ?? "NIL"
                print("  • \(mailbox.name) [delimiter: \(delimiter)] \(attrs)")
            }
        }
    }
    
    private func selectMailbox(client: IMAPClient) async throws {
        print("\nSelecting mailbox: \(mailbox)")
        let status = try await client.selectMailbox(mailbox)
        
        print("Mailbox status:")
        print("  Messages: \(status.messages)")
        print("  Recent: \(status.recent)")
        print("  Unseen: \(status.unseen)")
        print("  UID Next: \(status.uidNext)")
        print("  UID Validity: \(status.uidValidity)")
    }
    
    private func searchMessages(client: IMAPClient) async throws {
        print("\nSearching messages in \(mailbox)...")
        let messageNumbers = try await client.listMessages(in: mailbox)
        
        if messageNumbers.isEmpty {
            print("No messages found")
        } else {
            print("Found \(messageNumbers.count) messages")
            
            // For now, just show the sequence numbers
            // A more complete implementation would fetch details for each message
            if messageNumbers.count <= 50 {
                print("Sequence numbers: \(messageNumbers.map(String.init).joined(separator: ", "))")
            } else {
                let first20 = messageNumbers.prefix(20).map(String.init).joined(separator: ", ")
                print("Sequence numbers (first 20): \(first20)...")
                print("(Showing 20 of \(messageNumbers.count) total messages)")
            }
            
            print("\nTip: To see message details, use the interactive mode or fetch command with a specific UID")
            print("Note: Sequence numbers are temporary and change when messages are added/deleted")
        }
    }
    
    private func fetchMessage(client: IMAPClient, uid: UID) async throws {
        print("\nFetching message with UID \(uid) from \(mailbox)...")
        
        guard let summary = try await client.fetchMessage(uid: uid, in: mailbox) else {
            print("Message not found")
            return
        }
        
        print("\nMessage Summary:")
        print("  UID: \(summary.uid)")
        print("  Sequence Number: \(summary.sequenceNumber)")
        print("  Internal Date: \(summary.internalDate)")
        print("  Size: \(summary.size) bytes")
        print("  Flags: \(summary.flags.map { $0.rawValue }.joined(separator: ", "))")
        
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
                print("  Date: \(date)")
            }
        }
        
        print("\nFetching message body...")
        if let bodyData = try await client.fetchMessageBody(uid: uid, in: mailbox) {
            print("Body size: \(bodyData.count) bytes")
            
            if let bodyString = String(data: bodyData.prefix(1000), encoding: .utf8) {
                print("\nBody preview (first 1000 bytes):")
                print("---")
                print(bodyString)
                if bodyData.count > 1000 {
                    print("... (truncated)")
                }
                print("---")
            }
        }
    }
}