import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor CompletionBodyClient: DecisionClient {
    var responses: [CompletionBody?]
    let suspended: Bool
    private var pending: CheckedContinuation<CompletionBody?, Never>?
    private(set) var requests = 0

    init(_ responses: [CompletionBody?] = [], suspended: Bool = false) {
        self.responses = responses
        self.suspended = suspended
    }

    func completionBody(_ pairing: PairingPayload, sessionId: String, completionId: String) async -> CompletionBody? {
        requests += 1
        if suspended { return await withCheckedContinuation { pending = $0 } }
        return responses.removeFirst()
    }

    func resolve(_ body: CompletionBody) { pending?.resume(returning: body); pending = nil }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { false }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

@MainActor
final class CompletionBodyStoreTests: XCTestCase {
    private let pairing = PairingPayload(host: "completion-test", port: 9, token: "test")
    private var session: AgentSession {
        var session = AgentSession(id: "task", agent: .codex, project: "QA", status: .done,
                                   statusSince: Date(), updatedAt: Date())
        session.completionID = "round"
        return session
    }
    private var body: CompletionBody {
        CompletionBody(sourceID: "mac", sessionID: "task", completionID: "round", text: "Late final body")
    }

    private func connect(_ store: DashboardStore, pairing: PairingPayload) async throws {
        store.start(pairing)
        for _ in 0..<100 where store.state != .connected { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state, .connected)
        XCTAssertEqual(store.completionSourceID, "mac")
    }

    private func store(_ client: CompletionBodyClient) -> DashboardStore {
        DashboardStore(streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [session], serverTime: Date(), sourceID: "mac")]),
                       notifier: SilentNotifier(), decisionClient: client, watchRelay: nil, reportDevice: { _ in })
    }

    func testUnavailableAndNetworkFailureRemainRetryableForSameCompletion() async throws {
        let unavailable = CompletionBody(sourceID: "mac", sessionID: "task", completionID: "round",
                                         unavailableReason: "transcript_pending")
        let client = CompletionBodyClient([unavailable, nil, body])
        let store = store(client)
        try await connect(store, pairing: pairing)
        let first = await store.completionBody(for: session)
        let failed = await store.completionBody(for: session)
        let recovered = await store.completionBody(for: session)
        XCTAssertEqual(first, unavailable)
        XCTAssertNil(failed)
        XCTAssertEqual(recovered, body)
        let requests = await client.requests
        XCTAssertEqual(requests, 3)
        await store.stop().value
    }

    func testRejectsResponseForAnotherSessionOrCompletion() async throws {
        var wrongSession = body
        wrongSession.sessionID = "other-task"
        var wrongCompletion = body
        wrongCompletion.completionID = "other-round"
        let store = store(CompletionBodyClient([wrongSession, wrongCompletion]))
        try await connect(store, pairing: pairing)
        let first = await store.completionBody(for: session)
        let second = await store.completionBody(for: session)
        XCTAssertNil(first)
        XCTAssertNil(second)
        await store.stop().value
    }

    func testDiscardsInFlightResponseAfterSameSourceRepaired() async throws {
        let client = CompletionBodyClient(suspended: true)
        let store = store(client)
        try await connect(store, pairing: pairing)
        let request = Task { await store.completionBody(for: session) }
        for _ in 0..<100 {
            if await client.requests == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await connect(store, pairing: PairingPayload(host: "completion-test", port: 9, token: "replacement"))
        await client.resolve(body)
        let result = await request.value
        XCTAssertNil(result)
        await store.stop().value
    }
}
