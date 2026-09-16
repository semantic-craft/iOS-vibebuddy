import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor RecapClient: DecisionClient {
    var events: [String] = []
    var failedOnce = false
    var hold = false
    var pending: CheckedContinuation<CompletionReadOutcome, Never>?
    func holdNext() { hold = true }
    func isHeld() -> Bool { pending != nil }
    func release() { pending?.resume(returning: .accepted); pending = nil }
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome {
        events.append(request.completionID)
        if hold { hold = false; return await withCheckedContinuation { pending = $0 } }
        if request.completionID == "round-b", !failedOnce { failedOnce = true; return .failed }
        return .accepted
    }
    func advanceRecapHorizon(_ pairing: PairingPayload, request: RecapReadRequest) async -> RecapReadOutcome {
        events.append("horizon:" + String(Int(request.horizon.timeIntervalSince1970)))
        return .accepted
    }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { false }
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

@MainActor
final class PhoneRecapTests: XCTestCase {
    private let pairing = PairingPayload(host: "recap-test", port: 9, token: "test")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func entry(_ completion: String, kind: RecapEntryKind = .completed, offset: TimeInterval = 0) -> RecapEntry {
        RecapEntry(id: "mac/task/" + completion, kind: kind, sessionID: "same-task",
                   completionID: kind == .completed ? completion : nil, agent: .codex, project: "p",
                   title: completion, points: [], endedAt: now.addingTimeInterval(offset))
    }
    private func connect(_ client: RecapClient, recap: Recap) async throws -> DashboardStore {
        let store = DashboardStore(streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [], serverTime: now, sourceID: "mac", recap: recap)]),
                                   notifier: SilentNotifier(), decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(pairing)
        for _ in 0..<100 where store.state != .connected { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.state, .connected)
        return store
    }
    private func finish(_ store: DashboardStore) async throws {
        for _ in 0..<100 where store.recapConfirmation.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.recapConfirmation.isRunning)
    }

    func testOriginalBatchRetriesFailedReadBeforeFrozenHorizon() async throws {
        let client = RecapClient()
        let recap = Recap(entries: [entry("round-a"), entry("round-b", offset: 1), entry("failed", kind: .failed, offset: 2)])
        let store = try await connect(client, recap: recap)
        store.confirmRecap(recap, source: "mac", epoch: store.recapPairingEpoch)
        try await finish(store)
        let initial = await client.events
        XCTAssertEqual(initial, ["round-a", "round-b"])
        XCTAssertTrue(store.recapConfirmation.canRetry)
        XCTAssertEqual(store.recapConfirmation.batch?.entryIDs, recap.entries.map(\.id))
        store.confirmRecap(Recap(entries: [entry("new-round", offset: 10)]), source: "mac", epoch: store.recapPairingEpoch)
        XCTAssertEqual(store.recapConfirmation.batch?.entryIDs, recap.entries.map(\.id))
        store.retryRecap()
        try await finish(store)
        let final = await client.events
        XCTAssertEqual(final, ["round-a", "round-b", "round-b", "horizon:1800000002"])
        XCTAssertTrue(store.recapConfirmation.isComplete)
        XCTAssertEqual(store.recap?.entries, recap.entries, "Read outcomes do not mutate authoritative snapshot counts")
        await store.stop().value
    }

    func testPairingChangeDuringReadCannotAdvanceHorizon() async throws {
        let client = RecapClient()
        let recap = Recap(entries: [entry("round-a")])
        let store = try await connect(client, recap: recap)
        await client.holdNext()
        store.confirmRecap(recap, source: "mac", epoch: store.recapPairingEpoch)
        for _ in 0..<100 { if await client.isHeld() { break }; try await Task.sleep(for: .milliseconds(10)) }
        let held = await client.isHeld()
        XCTAssertTrue(held)
        ConnectionStore.rotateEpoch()
        await client.release()
        try await finish(store)
        XCTAssertTrue(store.recapConfirmation.sourceChanged)
        let events = await client.events
        XCTAssertEqual(events, ["round-a"])
        await store.stop().value
    }
    func testSourceChangeRejectsLateReadAndForgetClearsCachedAuthority() async throws {
        let stream = AsyncThrowingStream<Snapshot, Error>.makeStream()
        let client = RecapClient()
        let recap = Recap(entries: [entry("round-a")])
        let store = DashboardStore(streamer: RecapStream(values: stream.stream), notifier: SilentNotifier(),
                                   decisionClient: client, watchRelay: nil, reportDevice: { _ in })
        store.start(pairing)
        stream.continuation.yield(Snapshot(sessions: [], serverTime: now, sourceID: "mac", recap: recap))
        for _ in 0..<100 where store.state != .connected { try await Task.sleep(for: .milliseconds(10)) }
        await client.holdNext()
        store.confirmRecap(recap, source: "mac", epoch: store.recapPairingEpoch)
        for _ in 0..<100 { if await client.isHeld() { break }; try await Task.sleep(for: .milliseconds(10)) }
        let held = await client.isHeld()
        XCTAssertTrue(held)
        stream.continuation.yield(Snapshot(sessions: [], serverTime: now, sourceID: "other", recap: Recap()))
        for _ in 0..<100 where store.completionSourceID != "other" { try await Task.sleep(for: .milliseconds(10)) }
        await client.release()
        await Task.yield()
        XCTAssertTrue(store.recapConfirmation.sourceChanged)
        XCTAssertFalse(store.recapConfirmation.isComplete)
        let events = await client.events
        XCTAssertEqual(events, ["round-a"])
        store.forgetPairing()
        XCTAssertNil(store.recapSourceID)
        XCTAssertNil(store.recap)
        XCTAssertFalse(store.recapAvailable)
        stream.continuation.finish()
    }

    func testSameSourceNewPairingCanStartAnExplicitFreshBatch() {
        let recap = Recap(entries: [entry("round-a")])
        var state = RecapConfirmation()
        XCTAssertTrue(state.begin(recap: recap, sourceID: "mac", available: true))
        state.invalidate()
        XCTAssertTrue(state.begin(recap: recap, sourceID: "mac", available: true))
        XCTAssertFalse(state.sourceChanged)
        XCTAssertEqual(state.batch?.entryIDs, recap.entries.map(\.id))
    }

}

private struct RecapStream: SnapshotStreaming {
    let values: AsyncThrowingStream<Snapshot, Error>
    func stream(_ pairing: PairingPayload) -> AsyncThrowingStream<Snapshot, Error> { values }
}
