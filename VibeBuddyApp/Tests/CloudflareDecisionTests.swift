import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

final class CloudflareDecisionTests: XCTestCase {
    func testMissingCredentialsLeaveDecisionAndAnswerUnsent() async throws {
        let direct = PairingPayload(host: "127.0.0.1", port: 9876, token: "fixture")
        let pairing = try XCTUnwrap(direct.usingCloudflare(
            origin: "https://missing-credentials.invalid", credentialID: UUID().uuidString))
        let client = HTTPDecisionClient()
        let decision = await client.decideResult(pairing, approvalId: "fixture", decision: .allow,
                                                requestID: "fixture")
        let answer = await client.answerResult(pairing, sessionId: "fixture", answer: "fixture")
        XCTAssertEqual(decision, .notSent(.cloudflareCredentialsUnavailable))
        XCTAssertEqual(answer, .notSent(.cloudflareCredentialsUnavailable))
        let probe = await client.probe(pairing)
        XCTAssertEqual(probe, .unreachable(.cloudflareCredentialsUnavailable))
    }
}
