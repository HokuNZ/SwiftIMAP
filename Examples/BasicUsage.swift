import Foundation
import SwiftIMAP

// Example: Basic IMAP Client Usage
@main
struct BasicUsageExample {
    static func main() async {
        // Configure the IMAP client
        let config = IMAPConfiguration(
            hostname: "imap.gmail.com",
            port: 993,
            tlsMode: .requireTLS,
            authMethod: .login(
                username: "your.email@gmail.com",
                password: "your-app-password"  // Use app-specific password for Gmail
            ),
            logLevel: .info
        )
        
        // Create the client
        let client = IMAPClient(configuration: config)
        
        do {
            // Connect and authenticate
            print("Connecting to \(config.hostname)...")
            try await client.connect()
            print("✓ Connected successfully!")
            
            // Get server capabilities
            let capabilities = try await client.capability()
            print("\nServer capabilities: \(capabilities.sorted().joined(separator: ", "))")
            
            // List all mailboxes
            print("\n📁 Listing mailboxes:")
            let mailboxes = try await client.listMailboxes()
            for mailbox in mailboxes {
                let icon = mailbox.name.lowercased().contains("inbox") ? "📥" :
                          mailbox.name.lowercased().contains("sent") ? "📤" :
                          mailbox.name.lowercased().contains("draft") ? "📝" :
                          mailbox.name.lowercased().contains("trash") ? "🗑️" : "📁"
                print("  \(icon) \(mailbox.name)")
            }
            
            // Select INBOX
            print("\n📥 Selecting INBOX...")
            let inboxStatus = try await client.selectMailbox("INBOX")
            print("  Total messages: \(inboxStatus.messages)")
            print("  Recent messages: \(inboxStatus.recent)")
            print("  Unseen messages: \(inboxStatus.unseen)")
            
            // Search for recent messages
            print("\n🔍 Searching for messages...")
            let messageUIDs = try await client.listMessages(
                in: "INBOX",
                searchCriteria: .all
            )
            
            print("  Found \(messageUIDs.count) messages")
            
            // Fetch details of the first 5 messages
            if !messageUIDs.isEmpty {
                print("\n📧 Fetching first 5 messages:")
                let messagesToFetch = Array(messageUIDs.prefix(5))
                
                for (index, uid) in messagesToFetch.enumerated() {
                    if let summary = try await client.fetchMessage(
                        uid: uid,
                        in: "INBOX",
                        items: [.uid, .flags, .internalDate, .envelope, .rfc822Size]
                    ) {
                        print("\n  Message \(index + 1):")
                        print("    UID: \(summary.uid)")
                        print("    Date: \(formatDate(summary.internalDate))")
                        print("    Size: \(formatSize(summary.size))")
                        
                        if let envelope = summary.envelope {
                            print("    From: \(envelope.from.first?.displayName ?? "Unknown")")
                            print("    Subject: \(envelope.subject ?? "(No subject)")")
                        }
                        
                        let flagStrings = summary.flags.map { $0.rawValue }
                        print("    Flags: \(flagStrings.isEmpty ? "None" : flagStrings.joined(separator: ", "))")
                    }
                }
            }
            
            // Disconnect
            print("\n👋 Disconnecting...")
            await client.disconnect()
            print("✓ Disconnected successfully!")
            
        } catch {
            print("❌ Error: \(error)")
            await client.disconnect()
        }
    }
    
    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    
    static func formatSize(_ bytes: UInt32) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
}