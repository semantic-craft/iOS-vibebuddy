import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor ReadRetryClient: DecisionClient {
    private(set) var requests: [CompletionReadRequest] = []
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome {
        requests.append(request)
        return request.sessionID == "offline" ? .failed : .accepted
    }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { false }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

@MainActor
final class PhoneCompletionReadsTests: XCTestCase {
    private func request(_ session: String = "task", round: String = "one") -> CompletionReadRequest {
        CompletionReadRequest(sourceID: "mac", sessionID: session, completionID: round)
    }
    private func location() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json") }
    private func snapshot(round: String = "one", unread: Bool = true, source: String? = "mac") -> Snapshot {
        var task = AgentSession(id: "task", agent: .claudeCode, project: "Task", status: .done,
                                hasUnreadCompletion: unread, statusSince: Date(), updatedAt: Date())
        task.completionID = round
        return Snapshot(sessions: [task], serverTime: Date(), sourceID: source)
    }

    func testReadsPersistBeforeDeliveryAndRestartRetainsBackoff() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = PhoneCompletionReads(url: url)
        try reads.viewed(request(), epoch: "epoch")
        try reads.viewed(request(), epoch: "epoch")
        XCTAssertEqual(PhoneCompletionReads(url: url).entries.count, 1)
        reads.received(.failed, request: request())
        let restored = PhoneCompletionReads(url: url)
        XCTAssertEqual(restored.entries.first?.failures, 1)
        XCTAssertGreaterThan(try XCTUnwrap(restored.entries.first?.retryAt), Date())
        for _ in 0..<20 { restored.received(.failed, request: request()) }
        XCTAssertLessThanOrEqual(try XCTUnwrap(restored.entries.first?.retryAt).timeIntervalSinceNow, 60)
    }

    func testAuthorityPrunesReadDeletedNewRoundAndSourceButNoDataDoesNot() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = PhoneCompletionReads(url: url)
        try reads.viewed(request(), epoch: "epoch")
        reads.reconcile(snapshot(source: nil), epoch: "epoch")
        XCTAssertEqual(reads.entries.count, 1)
        reads.reconcile(snapshot(unread: false), epoch: "epoch")
        XCTAssertTrue(reads.entries.isEmpty)
        XCTAssertTrue(reads.confirmed.contains(request()))
        reads.clear()
        try reads.viewed(request(), epoch: "epoch")
        reads.reconcile(snapshot(round: "two"), epoch: "epoch")
        XCTAssertTrue(reads.entries.isEmpty)
        try reads.viewed(request(round: "two"), epoch: "epoch")
        reads.received(.accepted, request: request())
        XCTAssertEqual(reads.entries.map(\.request), [request(round: "two")])
        reads.reconcile(Snapshot(sessions: [], serverTime: Date(), sourceID: "mac"), epoch: "epoch")
        XCTAssertTrue(reads.entries.isEmpty)
        try reads.viewed(request(), epoch: "epoch")
        reads.reconcile(snapshot(source: "other"), epoch: "epoch")
        XCTAssertTrue(reads.entries.isEmpty)
        try reads.viewed(request(), epoch: "epoch")
        reads.select(epoch: "new")
        XCTAssertTrue(PhoneCompletionReads(url: url).entries.isEmpty)
    }

    func testFailedItemDoesNotBlockAnotherAndSuccessSurvivesRestart() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let reads = PhoneCompletionReads(url: url)
        let client = ReadRetryClient()
        try reads.viewed(request("offline"), epoch: "epoch")
        try reads.viewed(request("online"), epoch: "epoch")
        reads.resume(pairing: PairingPayload(host: "localhost", port: 9, token: "test"),
                     sourceID: "mac", epoch: "epoch", client: client)
        defer { reads.pause() }
        for _ in 0..<100 where !reads.confirmed.contains(request("online")) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(reads.confirmed.contains(request("online")))
        XCTAssertEqual(PhoneCompletionReads(url: url).entries.map(\.request), [request("offline")])
        let sent = await client.requests
        XCTAssertEqual(Set(sent), Set([request("offline"), request("online")]))
    }
}
