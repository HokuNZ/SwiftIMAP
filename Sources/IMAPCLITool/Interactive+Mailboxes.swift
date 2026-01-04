import Foundation
import SwiftIMAP

extension Interactive {
    func listMailboxes(client: IMAPClient, pattern: String) async throws {
        print("Listing mailboxes with pattern '\(pattern)'...")
        let mailboxes = try await client.listMailboxes(reference: "", pattern: pattern)

        if mailboxes.isEmpty {
            print("No mailboxes found")
        } else {
            print("Found \(mailboxes.count) mailboxes:")
            for mailbox in mailboxes {
                let attrs = mailbox.attributes.isEmpty
                    ? ""
                    : " [\(mailbox.attributes.map { $0.rawValue }.joined(separator: " "))]"
                print("  - \(mailbox.name)\(attrs)")
            }
        }
    }

    func selectMailbox(client: IMAPClient, mailbox: String) async throws {
        print("Selecting mailbox '\(mailbox)'...")
        let status = try await client.selectMailbox(mailbox)

        print("Selected '\(mailbox)'")
        print("  Messages: \(status.messages)")
        print("  Recent: \(status.recent)")
        print("  Unseen: \(status.unseen)")
    }

    func showStatus(client: IMAPClient, mailbox: String) async throws {
        print("Getting status for '\(mailbox)'...")
        let status = try await client.mailboxStatus(mailbox)

        print("Status of '\(mailbox)':")
        print("  Messages: \(status.messages)")
        print("  Recent: \(status.recent)")
        print("  Unseen: \(status.unseen)")
        print("  UID Next: \(status.uidNext)")
        print("  UID Validity: \(status.uidValidity)")
    }

    func showCapabilities(client: IMAPClient) async throws {
        print("Getting server capabilities...")
        let capabilities = try await client.capability()

        print("Server capabilities:")
        for capability in capabilities.sorted() {
            print("  - \(capability)")
        }
    }
}
