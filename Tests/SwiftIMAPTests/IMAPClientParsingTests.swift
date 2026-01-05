import XCTest
@testable import SwiftIMAP

final class IMAPClientParsingTests: XCTestCase {
    func testParseEnvelopePreservesGroupAddresses() {
        let config = IMAPConfiguration(hostname: "example.com", authMethod: .login(username: "user", password: "pass"))
        let client = IMAPClient(configuration: config)

        let addresses: [IMAPResponse.AddressData] = [
            IMAPResponse.AddressData(name: nil, adl: nil, mailbox: "Friends", host: nil),
            IMAPResponse.AddressData(name: "Alice", adl: nil, mailbox: "alice", host: "example.com"),
            IMAPResponse.AddressData(name: "Bob", adl: nil, mailbox: "bob", host: "example.com"),
            IMAPResponse.AddressData(name: nil, adl: nil, mailbox: nil, host: nil),
            IMAPResponse.AddressData(name: "Carol", adl: nil, mailbox: "carol", host: "example.net")
        ]

        let envelopeData = IMAPResponse.EnvelopeData(
            date: nil,
            subject: nil,
            from: addresses,
            sender: nil,
            replyTo: nil,
            to: nil,
            cc: nil,
            bcc: nil,
            inReplyTo: nil,
            messageID: nil
        )

        let envelope = client.parseEnvelope(envelopeData)

        XCTAssertEqual(
            envelope.from.map { $0.emailAddress },
            ["alice@example.com", "bob@example.com", "carol@example.net"]
        )

        XCTAssertEqual(envelope.fromEntries.count, 2)

        if case .group(let name, let members) = envelope.fromEntries[0] {
            XCTAssertEqual(name, "Friends")
            XCTAssertEqual(members.map { $0.emailAddress }, ["alice@example.com", "bob@example.com"])
        } else {
            XCTFail("Expected group entry")
        }

        if case .mailbox(let address) = envelope.fromEntries[1] {
            XCTAssertEqual(address.emailAddress, "carol@example.net")
        } else {
            XCTFail("Expected mailbox entry")
        }
    }
}
