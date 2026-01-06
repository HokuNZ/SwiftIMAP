import XCTest
@testable import SwiftIMAP

final class SASLContinuationHandlerTests: XCTestCase {
    private actor ChallengeRecorder {
        private var challenges: [String?] = []

        func record(_ value: String?) {
            challenges.append(value)
        }

        func values() -> [String?] {
            challenges
        }
    }

    func testInitialResponseIsUsedOnceBeforeHandler() async throws {
        let recorder = ChallengeRecorder()
        let handler: IMAPConfiguration.SASLResponseHandler = { challenge in
            await recorder.record(challenge)
            return "next-response"
        }
        let continuation = IMAPClient.makeSaslContinuationHandler(
            initialResponse: "initial-response",
            responseHandler: handler
        )

        let first = try await continuation("challenge-1")
        let second = try await continuation("challenge-2")
        let recorded = await recorder.values()

        XCTAssertEqual(first, "initial-response")
        XCTAssertEqual(second, "next-response")
        XCTAssertEqual(recorded, ["challenge-2"])
    }

    func testHandlerUsedWhenInitialResponseIsNil() async throws {
        let recorder = ChallengeRecorder()
        let handler: IMAPConfiguration.SASLResponseHandler = { challenge in
            await recorder.record(challenge)
            return "handler-response"
        }
        let continuation = IMAPClient.makeSaslContinuationHandler(
            initialResponse: nil,
            responseHandler: handler
        )

        let first = try await continuation("challenge-1")
        let recorded = await recorder.values()

        XCTAssertEqual(first, "handler-response")
        XCTAssertEqual(recorded, ["challenge-1"])
    }
}
