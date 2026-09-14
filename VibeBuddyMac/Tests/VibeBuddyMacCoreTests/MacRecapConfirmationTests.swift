import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct MacRecapConfirmationTests {
    private func entry(_ id: String, at: Date, kind: RecapEntryKind = .completed, read: Bool = false) -> RecapEntry {
        RecapEntry(id: "mac/s/" + id, kind: kind, sessionID: "s", completionID: kind == .completed ? id : nil,
                   agent: .codex, project: "project", title: id, points: [], endedAt: at, isRead: read)
    }

    @Test("An authoritative missing session is skipped without blocking later recap batches")
    func unavailableRoundDoesNotBlockNextBatch() throws {
        let now = Date()
        var state = MacRecapConfirmation()
        let started = state.begin(recap: Recap(entries: [entry("gone", at: now)]), sourceID: "mac", available: true)
        #expect(started)
        let attempt = try #require(state.attemptID)
        let request = try #require(state.batch?.completions.first)
        #expect(state.pendingHorizonRequest == nil)
        state.receiveCompletion(.unavailable, request: request, attemptID: attempt)
        #expect(state.pendingHorizonRequest != nil)
        state.receiveHorizon(.accepted, attemptID: attempt)
        state.finish(attemptID: attempt)
        #expect(state.isComplete)
        #expect(state.skippedCount == 1)
        #expect(state.outcomes[request] == .unavailable)
        let next = state.begin(recap: Recap(entries: [entry("next", at: now.addingTimeInterval(1))]), sourceID: "mac", available: true)
        #expect(next)
        #expect(state.batch?.completions.first?.completionID == "next")
    }

    @Test("A fixed batch excludes read and failed rounds, does not expand, and stops on source change")
    func frozenBatchAndFencing() throws {
        let now = Date()
        let displayed = Recap(entries: [entry("a", at: now), entry("failed", at: now.addingTimeInterval(1), kind: .failed),
                                       entry("read", at: now.addingTimeInterval(-1), read: true)])
        var state = MacRecapConfirmation()
        let unavailableBegin = state.begin(recap: displayed, sourceID: "mac", available: false)
        #expect(!unavailableBegin)
        let initialBegin = state.begin(recap: displayed, sourceID: "mac", available: true)
        #expect(initialBegin)
        let attempt = try #require(state.attemptID)
        let batch = try #require(state.batch)
        #expect(batch.horizon == now.addingTimeInterval(1))
        #expect(batch.completions.map(\.completionID) == ["a"])
        let duplicateBegin = state.begin(recap: displayed, sourceID: "mac", available: true)
        #expect(!duplicateBegin)
        state.receiveCompletion(.failed, request: batch.completions[0], attemptID: attempt)
        #expect(state.pendingHorizonRequest == nil)
        state.finish(attemptID: attempt)
        let newer = Recap(entries: [entry("b", at: now.addingTimeInterval(2))])
        let expandedBegin = state.begin(recap: newer, sourceID: "mac", available: true)
        #expect(!expandedBegin)
        #expect(state.batch == batch)
        let retriedBatch = state.retry(sourceID: "mac", available: true)
        #expect(retriedBatch)
        let retry = try #require(state.attemptID)
        state.receiveCompletion(.accepted, request: batch.completions[0], attemptID: attempt)
        #expect(state.pendingCompletions == batch.completions) // late previous-attempt receipt ignored
        state.observeSource("other")
        state.receiveCompletion(.accepted, request: batch.completions[0], attemptID: retry)
        #expect(state.sourceChanged)
        #expect(!state.isComplete)
        let oldSourceRetry = state.retry(sourceID: "mac", available: true)
        #expect(!oldSourceRetry)
        #expect(state.pendingCompletions == batch.completions)
    }

    @Test("Another device's horizon update cannot discard a failed read; retry leaves the new round untouched")
    func partialFailureAndNewRound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("journal.json")
        let now = Date()
        let store = SessionStore(sourceID: "mac", journalURL: journal, now: now)
        func event(_ kind: HookEvent.Kind, at: TimeInterval) -> HookEvent {
            HookEvent(kind: kind, sessionID: "s", agent: .claudeCode, cwd: "/x/project", timestamp: now.addingTimeInterval(at))
        }
        await store.ingest(event(.userPromptSubmit, at: 0))
        await store.ingest(event(.stop, at: 1))
        let recap = try #require(await store.snapshot(now: now.addingTimeInterval(2)).recap)
        var state = MacRecapConfirmation()
        let partialBegin = state.begin(recap: recap, sourceID: "mac", available: true)
        #expect(partialBegin)
        let attempt = try #require(state.attemptID)
        let batch = try #require(state.batch)
        let request = try #require(batch.completions.first)
        // A different device confirms the shared horizon while our fixed
        // batch is still running. It is not an acknowledgement of our reads.
        let horizonOutcome = await store.advanceRecapHorizon(RecapReadRequest(sourceID: batch.sourceID, horizon: batch.horizon))
        #expect(horizonOutcome == .accepted)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        let readOutcome = await store.acknowledgeCompletion(request).outcome
        #expect(readOutcome == .failed)
        state.receiveCompletion(readOutcome, request: request, attemptID: attempt)
        state.finish(attemptID: attempt)
        let empty = await store.snapshot(now: now.addingTimeInterval(2))
        #expect(empty.recap?.entries.isEmpty == true)
        #expect(empty.sessions.first?.hasUnreadCompletion == true)
        state.observeSource(empty.sourceID)
        #expect(state.canRetry)
        #expect(state.pendingCompletions == [request])

        try FileManager.default.removeItem(at: journal)
        await store.ingest(event(.userPromptSubmit, at: 3))
        await store.ingest(event(.stop, at: 4))
        let staleRetry = state.retry(sourceID: "mac", available: true)
        #expect(staleRetry)
        let retry = try #require(state.attemptID)
        let stale = await store.acknowledgeCompletion(request).outcome
        #expect(stale == .staleCompletion)
        state.receiveCompletion(stale, request: request, attemptID: retry)
        let retriedHorizon = try #require(state.pendingHorizonRequest)
        state.receiveHorizon(await store.advanceRecapHorizon(retriedHorizon), attemptID: retry)
        state.finish(attemptID: retry)
        #expect(state.isComplete)
        #expect(state.skippedCount == 1)
        let completedBegin = state.begin(recap: recap, sourceID: "mac", available: true)
        #expect(!completedBegin)
        let fresh = await store.snapshot(now: now.addingTimeInterval(5))
        #expect(fresh.sessions.first?.hasUnreadCompletion == true)
        #expect(fresh.recap?.entries.count == 1)
        #expect(fresh.recap?.entries.first?.completionID != request.completionID)
    }

    @Test("A failed read withholds the horizon; retry covers only its original remainder before moving the horizon")
    func readFailureWithholdsHorizon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = root.appendingPathComponent("journal.json")
        let now = Date()
        let store = SessionStore(sourceID: "mac", journalURL: journal, now: now)
        for (index, sessionID) in ["a", "b"].enumerated() {
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: sessionID, timestamp: now))
            await store.ingest(HookEvent(kind: .stop, sessionID: sessionID, timestamp: now.addingTimeInterval(Double(index + 1))))
        }
        let recap = try #require(await store.snapshot(now: now.addingTimeInterval(3)).recap)
        var state = MacRecapConfirmation()
        let started = state.begin(recap: recap, sourceID: "mac", available: true)
        #expect(started)
        let attempt = try #require(state.attemptID)
        let batch = try #require(state.batch)
        let read = batch.completions[0]
        let failed = batch.completions[1]
        state.receiveCompletion(await store.acknowledgeCompletion(read).outcome, request: read, attemptID: attempt)
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        state.receiveCompletion(await store.acknowledgeCompletion(failed).outcome, request: failed, attemptID: attempt)
        #expect(state.outcomes[failed] == .failed)
        #expect(state.pendingCompletions == [failed])
        #expect(state.pendingHorizonRequest == nil)
        let partial = await store.snapshot(now: now.addingTimeInterval(3))
        #expect(partial.recap?.horizon == nil)
        #expect(partial.recap?.entries.count == 2)
        state.finish(attemptID: attempt)

        try FileManager.default.removeItem(at: journal)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: failed.sessionID, timestamp: now.addingTimeInterval(4)))
        await store.ingest(HookEvent(kind: .stop, sessionID: failed.sessionID, timestamp: now.addingTimeInterval(5)))
        let retried = state.retry(sourceID: "mac", available: true)
        #expect(retried)
        #expect(state.pendingCompletions == [failed])
        let retry = try #require(state.attemptID)
        state.receiveCompletion(await store.acknowledgeCompletion(failed).outcome, request: failed, attemptID: retry)
        #expect(state.outcomes[failed] == .staleCompletion)
        let horizon = try #require(state.pendingHorizonRequest)
        #expect(horizon.horizon == batch.horizon)
        state.receiveHorizon(await store.advanceRecapHorizon(horizon), attemptID: retry)
        state.finish(attemptID: retry)
        #expect(state.isComplete)
        let after = await store.snapshot(now: now.addingTimeInterval(6))
        #expect(after.recap?.entries.count == 1)
        #expect(after.recap?.entries.first?.sessionID == failed.sessionID)
        #expect(after.recap?.entries.first?.completionID != failed.completionID)
        #expect(after.sessions.first { $0.id == failed.sessionID }?.hasUnreadCompletion == true)
    }

    @Test("Accepted reads do not conceal a failed horizon and are not repeated on retry")
    func independentEffects() throws {
        var state = MacRecapConfirmation()
        let recap = Recap(entries: [entry("a", at: Date())])
        let independentBegin = state.begin(recap: recap, sourceID: "mac", available: true)
        #expect(independentBegin)
        let attempt = try #require(state.attemptID)
        let request = try #require(state.pendingCompletions.first)
        state.receiveCompletion(.alreadyAcknowledged, request: request, attemptID: attempt)
        #expect(state.pendingHorizonRequest != nil)
        state.receiveHorizon(.failed, attemptID: attempt)
        state.finish(attemptID: attempt)
        #expect(state.canRetry)
        #expect(state.pendingCompletions.isEmpty)
        #expect(!state.isComplete)
        let horizonRetry = state.retry(sourceID: "mac", available: true)
        #expect(horizonRetry)
        let retry = try #require(state.attemptID)
        state.receiveHorizon(.accepted, attemptID: retry)
        state.finish(attemptID: retry)
        #expect(state.isComplete)
    }
}
