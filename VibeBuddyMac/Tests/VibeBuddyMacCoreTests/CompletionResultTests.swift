import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

// Several tests pin resultClock; a regression there loops instead of expiring.
@Suite("Completion results", .timeLimit(.minutes(1)))
struct CompletionResultTests {
    @Test func codexRealMappingAndStore() async throws {
        var parser = CodexAppServerReducer()
        let start = Date()
        // Pinned so a loaded run cannot age the result past its two-second window.
        let store = SessionStore(sourceID: "source", resultClock: { start })
        for event in parser.handle(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "t"]]], receivedAt: start) {
            await store.ingest(event)
        }
        _ = parser.handle(["method": "item/completed", "params": ["threadId": "s", "turnId": "t", "item": ["type": "agentMessage", "phase": "final_answer", "text": "Fixed. Device not verified."]]], receivedAt: start)
        let stop = parser.handle(["method": "turn/completed", "params": ["threadId": "s", "turn": ["id": "t", "status": "completed"]]], receivedAt: start)[0]
        await store.ingest(stop)
        let id = try #require(await store.snapshot(now: start).sessions.first?.completionID)
        let result = await store.completionResult(sessionID: "s", completionID: id)
        guard case .ready(let frozen) = result else { Issue.record("Missing final result"); return }
        #expect(frozen.finalText == "Fixed. Device not verified.")
        #expect(frozen.completedAt == start)
        #expect(frozen.turnID == "t")
        await store.ingest(stop)
        #expect(await store.completionResult(sessionID: "s", completionID: id) == result)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, observationSource: .appserver, timestamp: Date(), turnID: "new"))
        await store.ingest(stop)
        #expect(await store.completionResult(sessionID: "s", completionID: id) == .cancelled)
    }

    @Test func delayedVerifiedResultRemainsReadableWithoutRevivingNotification() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(sourceID: "source", journalURL: directory.appendingPathComponent("lifecycle.json"))
        let ended = Date().addingTimeInterval(-10)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "late", agent: .codex,
            timestamp: ended.addingTimeInterval(-10), turnID: "turn"))
        await store.ingest(HookEvent(kind: .stop, sessionID: "late", agent: .codex, timestamp: ended))
        await store.ingest(HookEvent(kind: .stop, sessionID: "late", agent: .codex, timestamp: ended,
            turnID: "turn", completionText: "Search is ready. Voice remains unverified.", completionSucceeded: true))
        let id = try #require(await store.snapshot(now: Date()).sessions.first?.completionID)
        #expect(await store.completionResult(sessionID: "late", completionID: id) == .expired)
        let body = await store.completionBody(sessionID: "late", completionID: id)
        #expect(body.text == "Search is ready. Voice remains unverified.")
        #expect(await store.snapshot(now: Date()).sessions.first?.hasUnreadCompletion == true)
        await store.ingest(HookEvent(kind: .stop, sessionID: "late", agent: .codex, timestamp: ended,
            turnID: "turn", completionText: "A duplicate must not replace the result.", completionSucceeded: true))
        #expect(await store.completionBody(sessionID: "late", completionID: id).text == nil)
        #expect(await store.completionBody(sessionID: "late", completionID: id).unavailableReason?.contains("Conflicting") == true)
        await store.ingest(HookEvent(kind: .stop, sessionID: "late", agent: .codex, timestamp: ended,
            turnID: "turn", completionText: body.text, completionSucceeded: true))
        #expect(await store.completionBody(sessionID: "late", completionID: id).text == nil)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "late", agent: .codex,
            timestamp: Date(), turnID: "new-turn"))
        #expect(await store.completionResult(sessionID: "late", completionID: id, forReading: true) == .cancelled)
        _ = await store.snapshot(now: Date())
        let key = CompletionResults.key(sourceID: "source", sessionID: "late", completionID: id)
        #expect(CompletionResultLedger(url: directory.appendingPathComponent(CompletionResultLedger.fileName)).results[key]?.text == body.text)
    }

    @Test func claudeTerminalProof() async throws {
        let start = Date().addingTimeInterval(-0.3)
        let ended = Date().addingTimeInterval(-0.1)
        let observed = ended.addingTimeInterval(0.1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let row: [String: Any] = ["sessionId": "s", "type": "assistant", "timestamp": formatter.string(from: start.addingTimeInterval(0.1)), "message": ["role": "assistant", "stop_reason": "end_turn", "content": [["type": "text", "text": "Done, not deployed."]]]]
        var bytes = try JSONSerialization.data(withJSONObject: row)
        bytes.append(10)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = SessionStore(sourceID: "source", resultClock: { observed })
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", timestamp: start))
        let stop = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s", "transcript_path": path.path, "last_assistant_message": "Done, not deployed."])
        await store.ingest(stop, receivedAt: ended)
        let id = try #require(await store.snapshot(now: ended).sessions.first?.completionID)
        guard case .ready(let value) = await store.completionResult(sessionID: "s", completionID: id) else { Issue.record("No Claude proof"); return }
        #expect(value.finalText == "Done, not deployed.")
        #expect(value.turnID == nil)
        #expect(ClaudeCompletionReader.parse(bytes.dropLast(), sessionID: "s", startedAt: start, completedAt: ended, expectedText: nil) == nil)
        #expect(ClaudeCompletionReader.parse(bytes, sessionID: "s", startedAt: ended, completedAt: ended, expectedText: nil) == nil)
        #expect(ClaudeCompletionReader.parse(bytes, sessionID: "s", startedAt: start, completedAt: ended, expectedText: "Other turn") == nil)
    }

    @Test func limitsAndInvalidEndings() {
        let now = Date()
        var reducer = SessionReducer()
        var results = CompletionResults()
        func apply(_ event: HookEvent) {
            let previous = reducer.sessions["s"]?.completionID
            reducer.apply(event)
            results.observe(event, session: reducer.sessions["s"], sourceID: "source", now: now,
                createdCompletion: reducer.sessions["s"]?.completionID != previous)
        }
        apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "t"))
        apply(HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: now, turnID: "t", completionText: String(repeating: "a", count: 12_001), completionSucceeded: true))
        #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultTooLong))
        apply(HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: now, turnID: "t", probeRetirement: true))
        #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultUnavailable))
        apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "new"))
        apply(HookEvent(kind: .stop, sessionID: "s", agent: .codex, message: "Turn interrupted", timestamp: now, turnID: "new", completionSucceeded: false))
        #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultUnavailable))
    }
    @Test func unknownRunAndOpaqueFailureFailClosed() throws {
        let now = Date()
        var reducer = SessionReducer()
        var results = CompletionResults()
        func apply(_ event: HookEvent) {
            let previous = reducer.sessions["s"]?.completionID
            reducer.apply(event)
            results.observe(event, session: reducer.sessions["s"], sourceID: "source", now: now,
                createdCompletion: reducer.sessions["s"]?.completionID != previous)
        }
        apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "old"))
        let stop = HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: now,
                             turnID: "old", completionText: "Old result", completionSucceeded: true)
        apply(stop)
        apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now))
        apply(stop)
        #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultUnavailable))
        apply(HookEvent(kind: .userPromptSubmit, sessionID: "s", timestamp: now))
        let failure = try #require(HookParser.parse(Data(#"{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit"}"#.utf8), receivedAt: now))
        #expect(failure.completionSucceeded == false)
        apply(failure)
        #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultUnavailable))
    }

    @Test func lateItemUsesOriginalDeadline() async throws {
        var parser = CodexAppServerReducer()
        let now = Date()
        let store = SessionStore(sourceID: "source", resultClock: { now })
        for event in parser.handle(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "t"]]], receivedAt: now) { await store.ingest(event) }
        for event in parser.handle(["method": "turn/completed", "params": ["threadId": "s", "turn": ["id": "t", "status": "completed"]]], receivedAt: now) { await store.ingest(event) }
        let id = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        let events = parser.handle(["method": "item/completed", "params": ["threadId": "s", "turnId": "t", "item": ["type": "agentMessage", "phase": "final_answer", "text": "Late final"]]], receivedAt: now.addingTimeInterval(0.1))
        #expect(events.first?.timestamp == now)
        for event in events { await store.ingest(event) }
        guard case .ready(let frozen) = await store.completionResult(sessionID: "s", completionID: id) else { Issue.record("Missing delayed final"); return }
        #expect(frozen.completedAt == now)
        var reducer = SessionReducer()
        var results = CompletionResults()
        let prompt = HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "t")
        reducer.apply(prompt)
        results.observe(prompt, session: reducer.sessions["s"], sourceID: "source", now: now, createdCompletion: true)
        let event = try #require(events.first)
        reducer.apply(event)
        results.observe(event, session: reducer.sessions["s"], sourceID: "source", now: now.addingTimeInterval(2.01), createdCompletion: true)
        #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.expired))
    }

    @Test func failedEndingCannotReviveFromLateItem() {
        for withTurnID in [true, false] {
            var parser = CodexAppServerReducer()
            var reducer = SessionReducer()
            var results = CompletionResults()
            let now = Date()
            func ingest(_ message: [String: Any]) {
                for event in parser.handle(message, receivedAt: now) {
                    let previous = reducer.sessions["s"]?.completionID
                    reducer.apply(event)
                    results.observe(event, session: reducer.sessions["s"], sourceID: "source", now: now,
                        createdCompletion: reducer.sessions["s"]?.completionID != previous)
                }
            }
            ingest(["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "t"]]])
            ingest(["method": "turn/completed", "params": ["threadId": "s", "turn": ["id": "t", "status": "completed"]]])
            var params: [String: Any] = ["threadId": "s", "willRetry": false, "error": ["message": "rate_limit"]]
            if withTurnID { params["turnId"] = "t" }
            ingest(["method": "error", "params": params])
            ingest(["method": "item/completed", "params": ["threadId": "s", "turnId": "t", "item": ["type": "agentMessage", "phase": "final_answer", "text": "Late final"]]])
            #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultUnavailable))
            ingest(["method": "turn/completed", "params": ["threadId": "s", "turn": ["id": "t", "status": "completed"]]])
            #expect(results.notificationState(sessionID: "s", completionID: reducer.sessions["s"]?.completionID ?? "", sourceID: "source") == .finished(.resultUnavailable))
        }
    }

    @Test func progressEndingWaitsForTerminalProof() async throws {
        let now = Date()
        let store = SessionStore(sourceID: "source", resultClock: { now })
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "t"))
        await store.ingest(HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: now))
        let id = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        let pending = Task { await store.completionResult(sessionID: "s", completionID: id) }
        await untilCompletionWaitParks(store)
        await store.ingest(HookEvent(kind: .stop, sessionID: "s", agent: .codex,
            timestamp: now.addingTimeInterval(0.06), turnID: "t", completionText: "Complete final",
            completionSucceeded: true))
        guard case .ready(let value) = await pending.value else { Issue.record("Returned before terminal proof"); return }
        #expect(value.completedAt == now)
        #expect(value.finalText == "Complete final")
    }

}

/// Returns once `store` has a `completionResult` call parked waiting for
/// terminal proof, so a test delivers that proof strictly afterwards. The
/// attempt bound is liveness only; the ordering never depends on elapsed time.
func untilCompletionWaitParks(_ store: SessionStore) async {
    for _ in 0..<5_000 {
        if await store.parkedCompletionWaits > 0 { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("completionResult never parked waiting for terminal proof")
}
