import Foundation
import SwiftIMAP

// Example: build the typed model from raw RFC 822 bytes, with no IMAP server.
//
// Useful for `.eml` importers, Maildir readers, webhook payloads, and offline
// test fixtures. Header parsing is independent of the MIME body, so an
// unparseable body still yields a populated envelope.
@main
struct OfflineParsingExample {
    static func main() throws {
        let raw = Data("""
        From: Alice <alice@example.com>
        To: Bob <bob@example.org>
        Subject: Lunch tomorrow?
        Date: Tue, 05 Oct 2021 11:03:08 -0400
        Message-ID: <msg-1@example.com>
        In-Reply-To: <thread-root@example.com>
        References: <thread-root@example.com>
        Content-Type: text/plain; charset=utf-8

        Are you free for lunch tomorrow?
        """.replacingOccurrences(of: "\n", with: "\r\n").utf8)

        // Whole message → MessageSummary (envelope + references populated).
        let summary = try MessageSummary.parse(rfc822: raw)
        print("From:    \(summary.envelope?.from.first?.displayName ?? "?")")
        print("Subject: \(summary.envelope?.subject ?? "?")")
        print("Date:    \(summary.internalDate)")
        print("Refs:    \(summary.references.map(\.value).joined(separator: ", "))")

        // Threading is bracket-safe: the parent id compares equal to a reference
        // regardless of how each was framed.
        if let parent = summary.envelope?.inReplyTo, summary.references.contains(parent) {
            print("Thread:  replies to a known ancestor (\(parent.value))")
        }

        // Body → MIME parts.
        if let mime = try MessageSummary.parseMIMEContent(from: raw) {
            print("Body:    \(mime.plainTextContent ?? "(none)")")
        }

        // Just a header dictionary → typed Envelope.
        let envelope = Envelope(parsingHeaders: ["From": "carol@example.net", "Subject": "Hi"])
        print("Headers-only sender: \(envelope.from.first?.emailAddress ?? "?")")
    }
}
