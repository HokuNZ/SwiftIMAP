import Foundation
import SwiftIMAP

extension Interactive {
    func searchMessages(client: IMAPClient, mailbox: String, criteria: String?) async throws {
        let searchResults: [MessageSummary]

        if let criteria = criteria {
            let parts = criteria.split(separator: " ", maxSplits: 1).map(String.init)
            let searchType = parts[0].lowercased()
            let searchValue = parts.count > 1 ? parts[1] : ""

            print("Searching messages with \(searchType): \(searchValue)...")

            switch searchType {
            case "from":
                searchResults = try await client.searchMessagesFrom(searchValue, in: mailbox, limit: 50)
            case "subject":
                searchResults = try await client.searchMessagesBySubject(searchValue, in: mailbox, limit: 50)
            case "text", "body":
                searchResults = try await client.searchMessagesByText(searchValue, in: mailbox, limit: 50)
            case "unread", "unseen":
                searchResults = try await client.searchUnreadMessages(in: mailbox, limit: 50)
            case "flagged", "starred":
                searchResults = try await client.searchFlaggedMessages(in: mailbox, limit: 50)
            case "since":
                var date: Date?
                if searchValue.hasSuffix("d"), let days = Int(searchValue.dropLast()) {
                    date = Calendar.current.date(byAdding: .day, value: -days, to: Date())
                } else if let parsedDate = parseDate(searchValue) {
                    date = parsedDate
                }

                if let date = date {
                    searchResults = try await client.searchMessagesSince(date, in: mailbox, limit: 50)
                } else {
                    print("Invalid date format. Use 'Nd' for N days ago (e.g., '7d') or YYYY-MM-DD")
                    return
                }
            case "all":
                print("Searching all messages...")
                let messageNumbers = try await client.listMessages(in: mailbox)
                print("Found \(messageNumbers.count) messages (showing first 50)")

                searchResults = try await client.searchMessages(
                    in: mailbox,
                    criteria: .all,
                    limit: 50
                )
            default:
                print("Unknown search type: \(searchType)")
                print("Available search types:")
                print("  from <email>     - Search by sender")
                print("  subject <text>   - Search by subject")
                print("  text <text>      - Search in message body")
                print("  unread           - Show unread messages")
                print("  flagged          - Show flagged/starred messages")
                print("  since <date>     - Messages since date (e.g., '7d' or '2024-01-01')")
                print("  all              - Show all messages")
                return
            }
        } else {
            print("Searching all messages...")
            searchResults = try await client.searchMessages(
                in: mailbox,
                criteria: .all,
                limit: 50
            )
        }

        if searchResults.isEmpty {
            print("No messages found")
        } else {
            print("\nFound \(searchResults.count) messages:")
            print(String(repeating: "=", count: 100))

            for summary in searchResults {
                let fromAddr = summary.envelope?.from.first
                let from = fromAddr?.displayName ?? fromAddr?.emailAddress ?? "Unknown"
                let subject = summary.envelope?.subject ?? "(No subject)"
                let date = formatMessageDate(summary.internalDate)
                let flags = summary.flags.map { $0.rawValue }.joined(separator: " ")

                print("\nUID: \(summary.uid)")
                print("  Date: \(date)")
                print("  From: \(from)")
                print("  Subject: \(subject)")
                if !flags.isEmpty {
                    print("  Flags: \(flags)")
                }
            }
        }
    }

    private func parseDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: dateString)
    }
}
