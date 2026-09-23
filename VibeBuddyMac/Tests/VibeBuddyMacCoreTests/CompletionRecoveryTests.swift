import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Completion recovery")
struct CompletionRecoveryTests {
    @Test("idle restored conversations obtain their exact native title without changing completion")
    func idleConversationTitle() async throws {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: index) }
        try Data("{\"id\":\"title-recovery-test\",\"thread_name\":\"Evening harbor drawing\"}\n".utf8).write(to: index)
        let store = SessionStore(sourceID: "source")
        let date = Date()
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "title-recovery-test", agent: .codex,
            observationSource: .appserver, timestamp: date, turnID: "a"))
        await store.ingest(.init(kind: .stop, sessionID: "title-recovery-test", agent: .codex,
            observationSource: .appserver, timestamp: date, turnID: "a", completionText: "Saved.", completionSucceeded: true))
        let before = try #require(await store.snapshot(now: date).sessions.first)
        await store.refreshCodexNames(index: index)
        let after = try #require(await store.snapshot(now: date).sessions.first)
        #expect(after.name == "Evening harbor drawing")
        #expect(after.status == before.status && after.completionID == before.completionID)
        #expect(after.updatedAt == before.updatedAt && after.hasUnreadCompletion == before.hasUnreadCompletion)
    }

    @Test("a corroborating native source can update the conversation name without ending app-server progress")
    func corroboratingConversationName() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now, turnID: "a"))
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            sessionName: "Draw the evening harbor", observationSource: .rollout, timestamp: now, turnID: "a"))
        let session = try #require(await store.snapshot(now: now).sessions.first)
        #expect(session.name == "Draw the evening harbor")
        #expect(session.status == .working)
        #expect(session.completionID == nil)
    }

    @Test func restartPreservesExactBodyAndUnreadWithoutNotificationCapture() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = dir.appendingPathComponent("lifecycle.json")
        let now = Date()
        let store = SessionStore(sourceID: "source", journalURL: journal)
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "a"))
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, timestamp: now,
            turnID: "a", completionText: "Exact A", completionSucceeded: true))
        let snapshot = await store.snapshot(now: now)
        let completion = try #require(snapshot.sessions.first?.completionID)
        let restored = SessionStore(sourceID: "source", journalURL: journal)
        #expect(await restored.completionBody(sessionID: "s", completionID: completion).text == "Exact A")
        #expect(await restored.snapshot(now: now).sessions.first?.hasUnreadCompletion == true)
        #expect(await restored.completionResult(sessionID: "s", completionID: completion) == .resultUnavailable)
        let wrongSource = SessionStore(sourceID: "other", journalURL: journal)
        #expect(await wrongSource.completionBody(sessionID: "s", completionID: completion).text == nil)
    }

    @Test func lowPriorityEvidenceAndLateOldTurnDoNotMoveCurrentState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(sourceID: "source", journalURL: dir.appendingPathComponent("journal.json"))
        let now = Date()
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex, observationSource: .appserver, timestamp: now, turnID: "a"))
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .appserver,
            timestamp: now, turnID: "a", completionSucceeded: true))
        let a = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .rollout,
            timestamp: now, turnID: "a", completionText: "Verified A", completionSucceeded: true))
        #expect(await store.completionBody(sessionID: "s", completionID: a).text == "Verified A")
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex, observationSource: .appserver,
            timestamp: now.addingTimeInterval(1), turnID: "b"))
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .rollout,
            timestamp: now, turnID: "a", completionText: "Conflict A", completionSucceeded: true))
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        #expect(await store.snapshot(now: now).sessions.first?.completionID == nil)
        #expect(await store.completionBody(sessionID: "s", completionID: a).text == nil)
        let key = RecapEntry.completedID(sourceID: "source", sessionID: "s", completionID: a)
        let saved = RecapLedger(url: dir.appendingPathComponent("recap-ledger.json"))
        #expect(saved.results[key]?.text == "Verified A")
        #expect(saved.results[key]?.conflict == true)
        #expect(saved.entries[key]?.resultConflict == true)
        #expect(await store.snapshot(now: now).recap?.entries.first?.points.contains("Verified A") == false)
    }

    @Test func claudeStopTextDoesNotWaitForTranscript() async throws {
        let now = Date()
        let store = SessionStore(sourceID: "source")
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "c", timestamp: now))
        let stop = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "c",
            "transcript_path": "/nonexistent/lagging.jsonl", "last_assistant_message": "Direct final reply"])
        await store.ingest(stop, receivedAt: now)
        let id = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        #expect(await store.completionBody(sessionID: "c", completionID: id).text == "Direct final reply")
    }

    @Test func durableConflictAndExpiryAreSticky() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let record = CompletionResults.Record(sourceID: "source", sessionID: "s", completionID: "completion",
            agent: .codex, turnID: "turn", title: "Title", startedAt: now, completedAt: now)
        var ledger = RecapLedger(url: dir.appendingPathComponent("ledger.json"))
        ledger.retainResults([record.id: record], now: now)
        var results = CompletionResults(restoring: ledger)
        results.accept("First", id: record.id, now: now)
        results.accept("Other", id: record.id, now: now)
        results.accept("First", id: record.id, now: now)
        _ = results.retain(in: &ledger, now: now)
        let restored = RecapLedger(url: ledger.url)
        #expect(restored.results[record.id]?.text == "First")
        #expect(restored.results[record.id]?.conflict == true)
        #expect(restored.results[record.id]?.frozen(now: now) == nil)
        #expect(RecapLedger(url: ledger.url, now: now.addingTimeInterval(RecapLedger.retention + 1)).results.isEmpty)
        #expect(ledger.entries.isEmpty)
    }
    @Test func recoveredEvidenceRequiresItsOriginalSourceAndRecordBoundary() throws {
        let now = Date()
        func record(turn: String = "turn", start: Date? = nil, end: Date? = nil) -> CompletionResults.Record {
            CompletionResults.Record(sourceID: "source", sessionID: "s", completionID: "completion",
                agent: .codex, turnID: turn, title: "Title", startedAt: start ?? now,
                completedAt: end ?? now, transcriptPath: "/unused/read-request.jsonl")
        }
        let original = record()
        var ledger = RecapLedger(url: nil)
        ledger.retainResults([original.id: original], now: now)
        var results = CompletionResults(restoring: ledger)
        guard case .read(let request) = results.readPlan(key: original.id, sourceID: "source", now: now) else {
            Issue.record("Expected uncached source read"); return
        }
        let acceptedWrongSource = results.merge(.text("Wrong source"), for: request, sourceID: "other", now: now)
        #expect(!acceptedWrongSource)
        for replaced in [record(turn: "other"), record(start: now.addingTimeInterval(-1)), record(end: now.addingTimeInterval(1))] {
            var changedLedger = RecapLedger(url: nil)
            changedLedger.retainResults([replaced.id: replaced], now: now)
            var changed = CompletionResults(restoring: changedLedger)
            let acceptedStaleRead = changed.merge(.text("Stale read"), for: request, sourceID: "source", now: now)
            #expect(!acceptedStaleRead)
            _ = changed.retain(in: &changedLedger, now: now)
            #expect(changedLedger.results[original.id]?.text == nil)
        }
        let accepted = results.merge(.text("Verified result"), for: request, sourceID: "source", now: now)
        #expect(accepted)
        _ = results.retain(in: &ledger, now: now)
        #expect(ledger.results[original.id]?.text == "Verified result")
        #expect(results.notificationState(sessionID: "s", completionID: "completion", sourceID: "source", now: now)
            == .finished(.resultUnavailable))
    }

    @Test func claudeHistoricalIntervalDoesNotBorrowNewRound() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func row(_ offset: TimeInterval, _ text: String) throws -> Data {
            var bytes = try JSONSerialization.data(withJSONObject: ["sessionId": "s", "type": "assistant",
                "timestamp": formatter.string(from: start.addingTimeInterval(offset)),
                "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": text]]]])
            bytes.append(10)
            return bytes
        }
        let bytes = try row(1, "A") + row(5, "B")
        #expect(ClaudeCompletionReader.parse(bytes, sessionID: "s", startedAt: start,
            completedAt: start.addingTimeInterval(2), expectedText: nil) == "A")
        #expect(ClaudeCompletionReader.parse(bytes, sessionID: "other", startedAt: start,
            completedAt: start.addingTimeInterval(2), expectedText: nil) == nil)
        #expect(ClaudeCompletionReader.parse(bytes, sessionID: "s", startedAt: start.addingTimeInterval(2),
            completedAt: start.addingTimeInterval(3), expectedText: nil) == nil)
    }

    @Test func claudeLateFailureDoesNotEraseNewRun() {
        let now = Date()
        var results = CompletionResults()
        var reducer = SessionReducer()
        func apply(_ event: HookEvent, authority: Bool = true) {
            let previous = reducer.sessions["s"]?.completionID
            if authority { reducer.apply(event) }
            results.observe(event, session: reducer.sessions["s"], sourceID: "source", now: now, authoritative: authority,
                createdCompletion: reducer.sessions["s"]?.completionID != previous)
        }
        apply(.init(kind: .userPromptSubmit, sessionID: "s", timestamp: now))
        apply(.init(kind: .stop, sessionID: "s", timestamp: now.addingTimeInterval(1), completionText: "A", completionSucceeded: true))
        apply(.init(kind: .userPromptSubmit, sessionID: "s", timestamp: now.addingTimeInterval(2)))
        apply(.init(kind: .stop, sessionID: "s", timestamp: now.addingTimeInterval(1), completionSucceeded: false), authority: false)
        apply(.init(kind: .stop, sessionID: "s", timestamp: now.addingTimeInterval(3), completionText: "B", completionSucceeded: true))
        #expect(results.recapResults(for: Array(reducer.sessions.values), sourceID: "source").values.contains("B"))
    }

    @Test func newerCorroboratingRunPreventsReadingOldAuthorityCompletion() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now, turnID: "a"))
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now, turnID: "a", completionText: "A", completionSucceeded: true))
        let a = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(1), turnID: "b"))
        #expect(await store.snapshot(now: now).sessions.first?.completionID == a)
        #expect(await store.completionBody(sessionID: "s", completionID: a).text == nil)
    }

    @Test func anonymousFailureMustMatchAgentAndObservedTimeBoundary() throws {
        let now = Date()
        var results = CompletionResults()
        var reducer = SessionReducer()
        let prompt = HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex, timestamp: now, turnID: "b")
        reducer.apply(prompt)
        results.observe(prompt, session: reducer.sessions["s"], sourceID: "source", now: now)
        results.observe(.init(kind: .stop, sessionID: "s", timestamp: now, completionSucceeded: false),
            session: reducer.sessions["s"], sourceID: "source", now: now)
        results.observe(.init(kind: .stop, sessionID: "s", agent: .codex,
            timestamp: now.addingTimeInterval(-1), completionSucceeded: false),
            session: reducer.sessions["s"], sourceID: "source", now: now)
        let stop = HookEvent(kind: .stop, sessionID: "s", agent: .codex, timestamp: now,
            turnID: "b", completionText: "Surviving run", completionSucceeded: true)
        let previous = reducer.sessions["s"]?.completionID
        reducer.apply(stop)
        results.observe(stop, session: reducer.sessions["s"], sourceID: "source", now: now,
            createdCompletion: reducer.sessions["s"]?.completionID != previous)
        let session = try #require(reducer.sessions["s"])
        #expect(results.snapshotText(for: session, sourceID: "source") == "Surviving run")
    }

    @Test func authoritativeEndingWithoutCandidateCanRecoverAfterRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = dir.appendingPathComponent("journal.json")
        let now = Date()
        let store = SessionStore(sourceID: "source", journalURL: journal)
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .appserver,
            timestamp: now, turnID: "exact", completionSucceeded: true))
        let completion = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        let key = RecapEntry.completedID(sourceID: "source", sessionID: "s", completionID: completion)
        #expect(RecapLedger(url: dir.appendingPathComponent("recap-ledger.json")).results[key]?.startedAt == nil)
        let restored = SessionStore(sourceID: "source", journalURL: journal)
        await restored.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .rollout,
            timestamp: now, turnID: "exact", turnStartedAt: now.addingTimeInterval(-10),
            completionText: "Recovered exact ending", completionSucceeded: true))
        #expect(await restored.snapshot(now: now).sessions.first?.completionID == completion)
        #expect(await restored.completionBody(sessionID: "s", completionID: completion).text == "Recovered exact ending")
        #expect(await restored.snapshot(now: now).recap?.entries.isEmpty == true)
        #expect(await restored.completionResult(sessionID: "s", completionID: completion) == .resultUnavailable)
    }

    @Test func legacyCompletionCannotBeAssignedByLateNativeEnding() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = dir.appendingPathComponent("journal.json")
        let now = Date()
        let store = SessionStore(sourceID: "source", journalURL: journal)
        // A progress-only ending creates an opaque legacy completion with no turn proof.
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now))
        let legacy = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        let restored = SessionStore(sourceID: "source", journalURL: journal)
        await restored.ingest(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now, turnID: "unproven-old-turn", turnStartedAt: now.addingTimeInterval(-10),
            completionText: "Must not bind to the legacy UUID", completionSucceeded: true))
        let body = await restored.completionBody(sessionID: "s", completionID: legacy)
        #expect(body.text == nil)
        #expect(body.unavailableReason?.contains("mapping is unknown") == true)
    }

    @Test func olderNativeEndingCannotRefineNewAnonymousRun() {
        let now = Date()
        var results = CompletionResults()
        var session = AgentSession(id: "s", agent: .codex, project: "test", status: .done,
            completionID: "completion", statusSince: now, updatedAt: now)
        results.observe(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now), session: nil, sourceID: "source", now: now)
        results.observe(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(-1), turnID: "older",
            turnStartedAt: now.addingTimeInterval(-10), completionText: "Old result", completionSucceeded: true),
            session: session, sourceID: "source", now: now, createdCompletion: true)
        var ledger = RecapLedger(url: nil)
        _ = results.retain(in: &ledger, now: now)
        #expect(ledger.results.isEmpty)
        #expect(results.snapshotText(for: session, sourceID: "source") == nil)

        session.completionID = "current-completion"
        results.observe(.init(kind: .stop, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(1), turnID: "current",
            turnStartedAt: now.addingTimeInterval(-2), completionText: "Current result", completionSucceeded: true),
            session: session, sourceID: "source", now: now.addingTimeInterval(1), createdCompletion: true)
        #expect(results.snapshotText(for: session, sourceID: "source") == "Current result")
    }

    @Test func nativeEndingRefinesAnonymousAppServerStart() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        var parser = CodexRolloutParser()
        let formatter = ISO8601DateFormatter()
        func events(_ type: String, _ payload: [String: Any], at: Date) throws -> [HookEvent] {
            parser.parseEvents(try JSONSerialization.data(withJSONObject: ["type": type,
                "timestamp": formatter.string(from: at), "payload": payload]), receivedAt: now)
        }
        _ = try events("session_meta", ["id": "s", "originator": "Codex Desktop"], at: now)
        // Discovery time is later than the real turn's start, and has no turn identity.
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .appserver, timestamp: now.addingTimeInterval(-900)))
        for event in try events("event_msg", ["type": "task_started", "turn_id": "native-turn"],
            at: now.addingTimeInterval(-901)) { await store.ingest(event) }
        for event in try events("response_item", ["type": "message", "role": "assistant", "phase": "final_answer",
            "internal_chat_message_metadata_passthrough": ["turn_id": "native-turn"],
            "content": [["type": "output_text", "text": "First answer"]]], at: now.addingTimeInterval(-8)) {
            await store.ingest(event)
        }
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        #expect(await store.snapshot(now: now).sessions.first?.completionID == nil)
        // A phone follow-up may be consumed inside this same native turn.
        for event in try events("response_item", ["type": "message", "role": "user",
            "content": [["type": "input_text", "text": "Confirm phone receipt"]]], at: now.addingTimeInterval(-7)) {
            await store.ingest(event)
        }
        for event in try events("response_item", ["type": "message", "role": "assistant", "phase": "final_answer",
            "internal_chat_message_metadata_passthrough": ["turn_id": "native-turn"],
            "content": [["type": "output_text", "text": "Phone reply received"]]], at: now.addingTimeInterval(-1)) {
            await store.ingest(event)
        }
        for event in try events("event_msg", ["type": "task_complete", "turn_id": "native-turn",
            "last_agent_message": "Phone reply received"], at: now) { await store.ingest(event) }
        let id = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        #expect(await store.completionBody(sessionID: "s", completionID: id).text == "Phone reply received")
    }

    @Test func codexFinalAnswerThenTaskCompleteRetainsTheSameMapping() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now)
        var parser = CodexRolloutParser()
        func events(_ type: String, _ payload: [String: Any]) throws -> [HookEvent] {
            parser.parseEvents(try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": stamp,
                "payload": payload], options: [.sortedKeys]), receivedAt: now)
        }
        _ = try events("session_meta", ["id": "s", "originator": "Codex Desktop", "source": "vscode"])
        for event in try events("event_msg", ["type": "task_started", "turn_id": "native-turn"]) { await store.ingest(event) }
        for event in try events("response_item", ["type": "message", "role": "assistant", "phase": "final_answer",
            "content": [["type": "output_text", "text": "Final answer from the recorded shape"]]]) { await store.ingest(event) }
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        #expect(await store.snapshot(now: now).sessions.first?.completionID == nil)
        for event in try events("event_msg", ["type": "task_complete", "turn_id": "native-turn",
            "last_agent_message": "Final answer from the recorded shape"]) { await store.ingest(event) }
        let id = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        #expect(await store.completionBody(sessionID: "s", completionID: id).text == "Final answer from the recorded shape")
    }

    @Test func successfulHookBeforeNativeEndingKeepsExactObservedTurn() async throws {
        let store = SessionStore(sourceID: "source")
        let now = Date()
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(-10), turnID: "native-turn"))
        let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s",
            "last_assistant_message": "Hook text is not native turn proof"])
        await store.ingest(hook, agent: .codex, receivedAt: now)
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        #expect(await store.snapshot(now: now).sessions.first?.completionID == nil)
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .rollout,
            timestamp: now.addingTimeInterval(0.2), turnID: "native-turn", turnStartedAt: now.addingTimeInterval(-10),
            completionText: "Verified native final answer", completionSucceeded: true))
        let completion = try #require(await store.snapshot(now: now.addingTimeInterval(1)).sessions.first?.completionID)
        #expect(await store.completionBody(sessionID: "s", completionID: completion).text == "Verified native final answer")
    }

    @Test func nativeHookWithoutObservedStartWaitsForTerminalResultAndDoesNotReviveAfterRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = dir.appendingPathComponent("journal.json")
        let now = Date()
        let store = SessionStore(sourceID: "source", journalURL: journal, resultClock: { now })
        let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s",
            "turn_id": "native-a", "last_assistant_message": "Exact native Hook answer"])
        await store.ingest(hook, agent: .codex, receivedAt: now)
        let completion = try #require(await store.snapshot(now: now).sessions.first?.completionID)
        #expect(await store.completionBody(sessionID: "s", completionID: completion).text == nil)
        let pending = Task { await store.completionResult(sessionID: "s", completionID: completion) }
        await untilCompletionWaitParks(store)
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .rollout,
            timestamp: now, turnID: "native-a", completionText: "Verified native final", completionSucceeded: true))
        guard case .ready(let result) = await pending.value else {
            Issue.record("Fresh native Hook result is unavailable for a summary")
            return
        }
        #expect(result.turnID == "native-a")
        #expect(result.finalText == "Verified native final")
        let key = RecapEntry.completedID(sourceID: "source", sessionID: "s", completionID: completion)
        #expect(RecapLedger(url: dir.appendingPathComponent("recap-ledger.json")).results[key]?.startedAt == nil)
        let restored = SessionStore(sourceID: "source", journalURL: journal, resultClock: { now })
        #expect(await restored.completionBody(sessionID: "s", completionID: completion).text == result.finalText)
        #expect(await restored.completionResult(sessionID: "s", completionID: completion) == .resultUnavailable)
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            timestamp: now.addingTimeInterval(1), turnID: "native-b"))
        await store.ingest(hook, agent: .codex, receivedAt: now.addingTimeInterval(2))
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        #expect(await store.completionResult(sessionID: "s", completionID: completion) == .cancelled)
    }

    @Test func hookBlockedContinuationNeverAnnouncesAnIntermediateCompletion() async throws {
        let now = Date()
        let store = SessionStore(sourceID: "source", resultClock: { now })
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            observationSource: .rollout, timestamp: now.addingTimeInterval(-10), turnID: "same-turn"))
        let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s",
            "turn_id": "same-turn", "last_assistant_message": "Intermediate answer before Stop hook blocks"])
        await store.ingest(hook, agent: .codex, receivedAt: now)
        #expect(await store.snapshot(now: now).sessions.first?.completionID == nil)
        await store.ingest(hook, agent: .codex, receivedAt: now)
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        await store.ingest(.init(kind: .preToolUse, sessionID: "s", agent: .codex, toolName: "Shell",
            observationSource: .rollout, timestamp: now.addingTimeInterval(0.1), turnID: "same-turn"))
        #expect(await store.snapshot(now: now).sessions.first?.status == .working)
        await store.ingest(hook, agent: .codex, receivedAt: now.addingTimeInterval(0.2))
        #expect(await store.snapshot(now: now).sessions.first?.completionID == nil)
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, observationSource: .rollout,
            timestamp: now.addingTimeInterval(0.3), turnID: "same-turn", completionText: "Actual final answer",
            completionSucceeded: true))
        let completed = try #require(await store.snapshot(now: now.addingTimeInterval(1)).sessions.first?.completionID)
        #expect(await store.completionBody(sessionID: "s", completionID: completed).text == "Actual final answer")
        guard case .ready(let result) = await store.completionResult(sessionID: "s", completionID: completed) else {
            Issue.record("Final completion lost its native result after a Stop-hook continuation")
            return
        }
        #expect(result.finalText == "Actual final answer")
    }

}
