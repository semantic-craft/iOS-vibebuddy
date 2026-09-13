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

    @Test("a Claude round with no readable transcript records the round without a sentence")
    func claudeWithoutTranscript() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(prompt("s", agent: .claudeCode, at: 0))
        await store.ingest(stop("s", agent: .claudeCode, at: 30))
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

    @Test("a snapshot without a source id records nothing")
    func noSourceNoLedger() async throws {
        let store = SessionStore(sourceID: nil)
        await store.ingest(prompt("s", at: 0))
        await store.ingest(stop("s", at: 30))
        #expect(await store.snapshot(now: t0.addingTimeInterval(31)).recap?.entries.isEmpty == true)
    }
}
