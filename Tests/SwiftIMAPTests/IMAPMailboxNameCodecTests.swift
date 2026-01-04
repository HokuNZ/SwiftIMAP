import XCTest
@testable import SwiftIMAP

final class IMAPMailboxNameCodecTests: XCTestCase {
    func testDecodeModifiedUTF7Ampersand() {
        XCTAssertEqual(IMAPMailboxNameCodec.decode("A&-B"), "A&B")
    }
    
    func testDecodeModifiedUTF7NonASCII() {
        XCTAssertEqual(IMAPMailboxNameCodec.decode("Envoy&AOk-"), "Envoyé")
    }
    
    func testEncodeDecodeRoundTrip() {
        let original = "Projects/日本語"
        let encoded = IMAPMailboxNameCodec.encode(original)
        XCTAssertEqual(IMAPMailboxNameCodec.decode(encoded), original)
    }
}
