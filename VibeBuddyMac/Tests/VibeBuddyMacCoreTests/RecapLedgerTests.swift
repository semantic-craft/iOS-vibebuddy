import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Recap ledger — ended rounds reach the snapshot")
struct RecapLedgerTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func prompt(_ sid: String, agent: AgentKind = .codex, at: TimeInterval, turn: String = "turn") -> HookEvent {
        HookEvent(kind: .userPromptSubmit, sessionID: sid, agent: agent, cwd: "/x/" + sid,
                  timestamp: t0.addingTimeInterval(at), turnID: turn)
    }

    private func stop(_ sid: String, agent: AgentKind = .codex, at: TimeInterval, turn: String = "turn",
                      text: String? = "Deployed docs to production. Then more.", succeeded: Bool? = true,
                      userStopped: Bool = false) -> HookEvent {
        HookEvent(kind: .stop, sessionID: sid, agent: agent, cwd: "/x/" + sid,
                  timestamp: t0.addingTimeInterval(at), turnID: turn, userStopped: userStopped,
                  completionText: text, completionSucceeded: succeeded)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a clean stop records one completed entry with the round's facts; reading marks it, never removes it")
    func completedRound() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", at: 0))
        await store.ingest(stop("s", at: 30))
        let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap)
        let entry = try #require(recap.entries.first)
        #expect(recap.entries.count == 1)
        #expect(entry.kind == .completed)
        #expect(entry.sessionID == "s")
        #expect(entry.completionID != nil)
        #expect(entry.id == "mac/s/" + entry.completionID!)
        #expect(entry.title == "s")                 // project name stands in for a session without a name
        #expect(entry.points == ["Deployed docs to production."])
        #expect(entry.endedAt == t0.addingTimeInterval(30))
        #expect(entry.isRead == false)

        let read = CompletionReadRequest(sourceID: "mac", sessionID: "s", completionID: entry.completionID!)
        #expect(await store.acknowledgeCompletion(read, now: t0.addingTimeInterval(40)).outcome == .accepted)
        let after = try #require(await store.snapshot(now: t0.addingTimeInterval(41)).recap)
        #expect(after.entries.map(\.id) == [entry.id])
        #expect(after.entries.first?.isRead == true)
    }

    @Test("a failed ending records one failed entry, keyed by its moment, once")
    func failedRound() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", agent: .codex, at: 0))
        await store.ingest(stop("s", agent: .codex, at: 20, text: "Turn interrupted", succeeded: false))
        _ = await store.snapshot(now: t0.addingTimeInterval(21))
        let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(25)).recap)
        #expect(recap.entries.count == 1)
        let entry = try #require(recap.entries.first)
        #expect(entry.kind == .failed)
        #expect(entry.completionID == nil)
        #expect(entry.id == RecapEntry.failedID(sourceID: "mac", sessionID: "s", statusSince: t0.addingTimeInterval(20)))
        #expect(entry.isRead == false)
        #expect(recap.failedCount == 1)
    }

    @Test("attaching to an old Codex failure does not backfill it; the next live failed turn is recorded once")
    func failedAttachmentThenLiveRound() async throws {
        let store = SessionStore(sourceID: "mac")
        var source = CodexAppServerReducer()
        for event in source.seed(thread: ["id": "s", "cwd": "/x/s", "source": "cli",
                                          "status": ["type": "systemError"]], receivedAt: t0) {
            await store.ingest(event)
        }
        #expect(await store.snapshot(now: t0).recap?.entries.isEmpty == true)
        let messages: [[String: Any]] = [
            ["method": "turn/started", "params": ["threadId": "s", "turn": ["id": "t2"]]],
            ["method": "thread/status/changed", "params": ["threadId": "s", "status": ["type": "systemError"]]],
            ["method": "error", "params": ["threadId": "s", "turnId": "t2", "willRetry": false,
                                            "error": ["message": "Connection refused"]]],
            ["method": "turn/completed", "params": ["threadId": "s", "turn": ["id": "t2", "status": "failed"]]],
        ]
        for (index, message) in messages.enumerated() {
            for event in source.handle(message, receivedAt: t0.addingTimeInterval(Double(index + 1))) {
                await store.ingest(event)
            }
        }
        let entries = try #require(await store.snapshot(now: t0.addingTimeInterval(5)).recap?.entries)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .failed)
        #expect(entries.first?.endedAt == t0.addingTimeInterval(2))
    }

    @Test("a tool error during a running round is not a failed recap entry")
    func recoverableToolError() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", at: 0))
        await store.ingest(HookEvent(kind: .postToolUse, sessionID: "s", agent: .codex,
                                     toolName: "Shell", toolError: true, timestamp: t0.addingTimeInterval(1)))
        #expect(await store.snapshot(now: t0.addingTimeInterval(2)).recap?.entries.isEmpty == true)
        await store.ingest(stop("s", at: 3))
        let entries = try #require(await store.snapshot(now: t0.addingTimeInterval(4)).recap?.entries)
        #expect(entries.count == 1)
        #expect(entries.first?.kind == .completed)
    }

    @Test("a second round keeps the first; the recap is newest first")
    func twoRounds() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", at: 0, turn: "t1"))
        await store.ingest(stop("s", at: 30, turn: "t1", text: "First result."))
        _ = await store.snapshot(now: t0.addingTimeInterval(31))
        await store.ingest(prompt("s", at: 60, turn: "t2"))
        await store.ingest(stop("s", at: 90, turn: "t2", text: "Second result."))
        let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(91)).recap)
        #expect(recap.entries.map { $0.points.first } == ["Second result.", "First result."])
        #expect(recap.entries.map(\.endedAt) == [t0.addingTimeInterval(90), t0.addingTimeInterval(30)])
    }

    @Test("Claude Stop summaries belong to their round even while the transcript still contains the previous result")
    func claudeStopBeforeTranscriptFlush() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("transcript.jsonl")
        let oldRecord: [String: Any] = ["type": "assistant", "message": ["role": "assistant",
            "content": [["type": "text", "text": "2 + 2 = 4."]]]]
        var data = try JSONSerialization.data(withJSONObject: oldRecord)
        data.append(10)
        try data.write(to: transcript)
        let store = SessionStore(sourceID: "mac")
        for (index, text) in ["2 + 2 = 4.", "3 + 3 = 6."].enumerated() {
            let offset = TimeInterval(index * 30)
            let prompt = try JSONSerialization.data(withJSONObject: ["hook_event_name": "UserPromptSubmit",
                "session_id": "s", "transcript_path": transcript.path, "prompt": "Next calculation"])
            await store.ingest(prompt, receivedAt: t0.addingTimeInterval(offset))
            let stop = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop",
                "session_id": "s", "transcript_path": transcript.path, "last_assistant_message": text])
            await store.ingest(stop, receivedAt: t0.addingTimeInterval(offset + 10))
        }
        let snapshot = await store.snapshot(now: t0.addingTimeInterval(41))
        #expect(snapshot.recap?.entries.map { $0.points.first } == ["3 + 3 = 6.", "2 + 2 = 4."])
        #expect(snapshot.sessions.first?.summary == "3 + 3 = 6.")
        #expect(snapshot.sessions.first?.hasUnreadCompletion == true)

        // Without an exact Stop summary, do not invent one from the old tail.
        await store.ingest(prompt("s", agent: .claudeCode, at: 60))
        let silentStop = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop",
            "session_id": "s", "transcript_path": transcript.path])
        await store.ingest(silentStop, receivedAt: t0.addingTimeInterval(70))
        let after = await store.snapshot(now: t0.addingTimeInterval(71))
        #expect(after.recap?.entries.first?.points.isEmpty == true)
        #expect(after.sessions.first?.summary == nil)
    }

    @Test("Mark Unread puts a read round back into Mark all's reach")
    func markUnreadIsUnreadAgain() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", at: 0))
        await store.ingest(stop("s", at: 30))
        let entry = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.first)
        let completionID = try #require(entry.completionID)
        let read = CompletionReadRequest(sourceID: "mac", sessionID: "s", completionID: completionID)
        #expect(await store.acknowledgeCompletion(read, now: t0.addingTimeInterval(40)).outcome == .accepted)
        #expect(await store.snapshot(now: t0.addingTimeInterval(41)).recap?.entries.first?.isRead == true)

        let unread = CompletionReadRequest(sourceID: "mac", sessionID: "s", completionID: completionID, markUnread: true)
        #expect(await store.acknowledgeCompletion(unread, now: t0.addingTimeInterval(50)).outcome == .accepted)
        let after = try #require(await store.snapshot(now: t0.addingTimeInterval(51)).recap)
        #expect(after.entries.map(\.id) == [entry.id])
        #expect(after.entries.first?.isRead == false)
        var mac = RecapConfirmation()
        let started = mac.begin(recap: after, sourceID: "mac", available: true)
        #expect(started)
        #expect(mac.pendingCompletions == [read])
    }

    @Test("a round read before the next one stays read after the next one is read")
    func earlierRoundKeepsItsReadMark() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", at: 0, turn: "t1"))
        await store.ingest(stop("s", at: 30, turn: "t1", text: "First result."))
        let first = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.first)
        let firstID = try #require(first.completionID)
        let readFirst = CompletionReadRequest(sourceID: "mac", sessionID: "s", completionID: firstID)
        #expect(await store.acknowledgeCompletion(readFirst, now: t0.addingTimeInterval(40)).outcome == .accepted)
        #expect(await store.snapshot(now: t0.addingTimeInterval(41)).recap?.entries.first?.isRead == true)

        await store.ingest(prompt("s", at: 60, turn: "t2"))
        await store.ingest(stop("s", at: 90, turn: "t2", text: "Second result."))
        let second = try #require(await store.snapshot(now: t0.addingTimeInterval(91)).recap)
        #expect(second.entries.map(\.isRead) == [false, true])      // newest first: t2 unread, t1 still read

        let secondID = try #require(second.entries.first?.completionID)
        #expect(secondID != firstID)
        let readSecond = CompletionReadRequest(sourceID: "mac", sessionID: "s", completionID: secondID)
        #expect(await store.acknowledgeCompletion(readSecond, now: t0.addingTimeInterval(100)).outcome == .accepted)
        let both = try #require(await store.snapshot(now: t0.addingTimeInterval(101)).recap)
        #expect(both.entries.map(\.isRead) == [true, true])
    }

    @Test("an earlier round's read mark survives a restart")
    func readMarkPersists() async throws {
        let dir = try tempDir()
        let journal = dir.appendingPathComponent("lifecycle-journal.json")
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0)
            await store.ingest(prompt("s", at: 0, turn: "t1"))
            await store.ingest(stop("s", at: 30, turn: "t1", text: "First result."))
            let first = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.first)
            let read = CompletionReadRequest(sourceID: "mac", sessionID: "s", completionID: try #require(first.completionID))
            #expect(await store.acknowledgeCompletion(read, now: t0.addingTimeInterval(40)).outcome == .accepted)
            await store.ingest(prompt("s", at: 60, turn: "t2"))
            await store.ingest(stop("s", at: 90, turn: "t2", text: "Second result."))
            #expect(await store.snapshot(now: t0.addingTimeInterval(91)).recap?.entries.map(\.isRead) == [false, true])
        }
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0.addingTimeInterval(3600))
            let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(3600)).recap)
            #expect(recap.entries.map { $0.points.first } == ["Second result.", "First result."])
            #expect(recap.entries.last?.isRead == true)
        }
    }

    @Test("a Claude round with neither Stop text nor readable transcript records no sentence")
    func claudeWithoutTranscript() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", agent: .claudeCode, at: 0))
        await store.ingest(stop("s", agent: .claudeCode, at: 30, text: nil))
        let entry = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.first)
        #expect(entry.kind == .completed)
        #expect(entry.points.isEmpty)
    }

    @Test("a stop the user asked for leaves no entry")
    func userStopLeavesNothing() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", agent: .codex, at: 0))
        await store.ingest(stop("s", agent: .codex, at: 20, text: "Turn interrupted", succeeded: false, userStopped: true))
        let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(21)).recap)
        #expect(recap.entries.isEmpty)
    }

    @Test("a muted session's rounds stay on file but leave the recap; unmuting brings them back")
    func mutedFiltered() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", at: 0))
        await store.ingest(stop("s", at: 30))
        #expect(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.count == 1)
        _ = await store.setAttention(sessionID: "s", .muted)
        #expect(await store.snapshot(now: t0.addingTimeInterval(32)).recap?.entries.isEmpty == true)
        _ = await store.setAttention(sessionID: "s", nil)
        #expect(await store.snapshot(now: t0.addingTimeInterval(33)).recap?.entries.count == 1)
    }

    @Test("the ledger survives a restart and forgets rounds older than seven days")
    func persistence() async throws {
        let dir = try tempDir()
        let journal = dir.appendingPathComponent("lifecycle-journal.json")
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0)
            await store.ingest(prompt("s", at: 0))
            await store.ingest(stop("s", at: 30))
            #expect(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.count == 1)
        }
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recap-ledger.json").path))
        do {
            // Fresh process, one hour later: the round is still on file and still in the window.
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0.addingTimeInterval(3600))
            let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(3600)).recap)
            #expect(recap.entries.map(\.sessionID) == ["s"])
        }
        do {
            // Eight days later the file no longer carries it.
            let later = t0.addingTimeInterval(8 * 86_400)
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: later)
            #expect(await store.snapshot(now: later).recap?.entries.isEmpty == true)
        }
    }

    @Test("a settled notice summary replaces the fallback sentence")
    func noticeSummaryWins() async throws {
        let dir = try tempDir()
        let store = SessionStore(sourceID: "mac")
        await store.configureCompletionNotices(url: dir.appendingPathComponent("decisions.json"),
                                               enabled: { true }) { _ in "Docs shipped; three links fixed." }
        await store.ingest(prompt("s", agent: .codex, at: -60))
        _ = await store.setAttention(sessionID: "s", .followed)
        await store.ingest(stop("s", agent: .codex, at: 0, text: "Synthetic result. More text."))
        // The notice task runs off the store; give the actor a moment to settle it.
        var summary: String?
        for _ in 0..<50 {
            summary = await store.snapshot(now: t0.addingTimeInterval(1)).recap?.entries.first?.points.first
            if summary == "Docs shipped; three links fixed." { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(summary == "Docs shipped; three links fixed.")
    }

    @Test("Mark all moves the horizon forward only, narrows the recap, and reads nothing")
    func horizonAdvances() async throws {
        let store = SessionStore(sourceID: "mac")
        for (sid, at) in [("a", 10.0), ("b", 20.0), ("c", 30.0)] {
            await store.ingest(prompt(sid, at: 0))
            await store.ingest(stop(sid, at: at))
        }
        let before = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap)
        #expect(before.entries.map(\.sessionID) == ["c", "b", "a"])
        #expect(before.horizon == nil)
        let unreadBefore = await store.snapshot(now: t0.addingTimeInterval(31)).sessions
            .map { ($0.id, $0.hasUnreadCompletion) }.sorted { $0.0 < $1.0 }

        // Another Mac's request is refused and changes nothing.
        #expect(await store.advanceRecapHorizon(RecapReadRequest(sourceID: "other", horizon: t0.addingTimeInterval(20)),
                                                now: t0.addingTimeInterval(32)) == .sourceMismatch)
        #expect(await store.snapshot(now: t0.addingTimeInterval(32)).recap?.horizon == nil)

        // Forward to the middle round: only the newest remains; reads are untouched.
        let middle = t0.addingTimeInterval(20)
        #expect(await store.advanceRecapHorizon(RecapReadRequest(sourceID: "mac", horizon: middle),
                                                now: t0.addingTimeInterval(33)) == .accepted)
        let after = try #require(await store.snapshot(now: t0.addingTimeInterval(34)).recap)
        #expect(after.horizon == middle)
        #expect(after.entries.map(\.sessionID) == ["c"])
        let unreadAfter = await store.snapshot(now: t0.addingTimeInterval(34)).sessions
            .map { ($0.id, $0.hasUnreadCompletion) }.sorted { $0.0 < $1.0 }
        #expect(unreadAfter.map(\.0) == unreadBefore.map(\.0))
        #expect(unreadAfter.map(\.1) == unreadBefore.map(\.1))
        #expect(unreadAfter.allSatisfy { $0.1 == true })

        // Backward and repeated requests are accepted and change nothing.
        #expect(await store.advanceRecapHorizon(RecapReadRequest(sourceID: "mac", horizon: t0.addingTimeInterval(10)),
                                                now: t0.addingTimeInterval(35)) == .accepted)
        #expect(await store.advanceRecapHorizon(RecapReadRequest(sourceID: "mac", horizon: middle),
                                                now: t0.addingTimeInterval(36)) == .accepted)
        #expect(await store.snapshot(now: t0.addingTimeInterval(37)).recap == after)
    }

    @Test("the horizon survives a restart without touching the journal")
    func horizonPersists() async throws {
        let dir = try tempDir()
        let journal = dir.appendingPathComponent("lifecycle-journal.json")
        let horizon = t0.addingTimeInterval(30)
        var journalBytes: Data?
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0)
            await store.ingest(prompt("s", at: 0))
            await store.ingest(stop("s", at: 30))
            _ = await store.snapshot(now: t0.addingTimeInterval(31))
            journalBytes = try Data(contentsOf: journal)
            #expect(await store.advanceRecapHorizon(RecapReadRequest(sourceID: "mac", horizon: horizon),
                                                    now: t0.addingTimeInterval(40)) == .accepted)
            #expect(try Data(contentsOf: journal) == journalBytes)   // horizon is not a lifecycle event
        }
        do {
            let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0.addingTimeInterval(3600))
            let recap = try #require(await store.snapshot(now: t0.addingTimeInterval(3600)).recap)
            #expect(recap.horizon == horizon)
            #expect(recap.entries.isEmpty)
            #expect(await store.snapshot(now: t0.addingTimeInterval(3600)).sessions.first?.hasUnreadCompletion == true)
        }
    }

    @Test("A failed horizon write preserves the visible recap and the same request can recover durably")
    func horizonWriteFailureAndRetry() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = dir.appendingPathComponent("lifecycle-journal.json")
        let ledger = dir.appendingPathComponent("recap-ledger.json")
        let store = SessionStore(sourceID: "mac", journalURL: journal, now: t0)
        await store.ingest(prompt("s", at: 0))
        await store.ingest(stop("s", at: 30))
        let before = try #require(await store.snapshot(now: t0.addingTimeInterval(31)).recap)
        let horizon = try #require(before.entries.first?.endedAt)
        let request = RecapReadRequest(sourceID: "mac", horizon: horizon)
        try FileManager.default.removeItem(at: ledger)
        try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: true)
        #expect(await store.advanceRecapHorizon(request, now: t0.addingTimeInterval(32)) == .failed)
        #expect(await store.snapshot(now: t0.addingTimeInterval(33)).recap == before)
        try FileManager.default.removeItem(at: ledger)
        #expect(await store.advanceRecapHorizon(request, now: t0.addingTimeInterval(34)) == .accepted)
        #expect(await store.advanceRecapHorizon(request, now: t0.addingTimeInterval(35)) == .accepted)
        let restored = SessionStore(sourceID: "mac", journalURL: journal, now: t0.addingTimeInterval(36))
        let after = await restored.snapshot(now: t0.addingTimeInterval(37))
        #expect(after.recap?.horizon == horizon)
        #expect(after.recap?.entries.isEmpty == true)
        #expect(after.sessions.first?.hasUnreadCompletion == true)
    }

    @Test("a snapshot without a source id records nothing")
    func noSourceNoLedger() async throws {
        let store = SessionStore(sourceID: nil)
        await store.ingest(prompt("s", at: 0))
        await store.ingest(stop("s", at: 30))
        #expect(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.isEmpty == true)
    }
}
