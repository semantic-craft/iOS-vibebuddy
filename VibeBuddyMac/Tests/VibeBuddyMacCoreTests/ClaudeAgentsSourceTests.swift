import Foundation
import Testing
@testable import VibeBuddyMacCore

/// AI-05: background sessions come from `claude agents --json --all`, run only
/// when something may have changed.
@Suite("claude agents --json source")
struct ClaudeAgentsSourceTests {
    /// Shape recorded from Claude Code 2.1.280 on 2026-09-23 (paths trimmed).
    static let sample = Data(#"""
    [
      {"id": "747978a2", "cwd": "/p/responsay", "kind": "background", "startedAt": 1781444893757,
       "sessionId": "747978a2-9efa-4859-8365-9f209d4fe9fe", "name": "brooks sweep", "state": "blocked"},
      {"id": "d6c8c5b9", "cwd": "/p/vb", "kind": "background", "startedAt": 1788875789061,
       "sessionId": "d6c8c5b9-a315-4587-99be-cd75c04032e4", "state": "done"},
      {"id": "abc12345", "kind": "background", "sessionId": "abc12345-0000-0000-0000-000000000000",
       "state": "blocked", "waitingFor": "permission prompt"},
      {"pid": 60827, "cwd": "/p/vb", "kind": "interactive", "startedAt": 1790133835212,
       "sessionId": "8abab909-ba56-43c9-96a9-5b8180b24e0f", "name": "cleanup", "status": "busy"},
      {"id": "../evil", "kind": "background", "sessionId": "x"}
    ]
    """#.utf8)

    @Test("background entries only; fields decoded as they appear; unsafe ids dropped")
    func parses() throws {
        let sessions = try #require(ClaudeBackgroundSessions.parseAgentsJSON(Self.sample))
        #expect(sessions.map(\.id) == ["747978a2", "abc12345", "d6c8c5b9"])
        #expect(sessions[0].name == "brooks sweep")
        #expect(sessions[0].state == "blocked")
        #expect(sessions[0].needs == nil)
        #expect(sessions[1].needs == "permission prompt")
        #expect(sessions[2].name == nil)
        #expect(ClaudeBackgroundSessions.parseAgentsJSON(Data("not json".utf8)) == nil)
    }

    @Test("a missing waitingFor is filled from that job's own needs line")
    func needsFromJobFile() throws {
        let sessions = try #require(ClaudeBackgroundSessions.parseAgentsJSON(Self.sample,
            jobNeeds: { $0 == "747978a2" ? "choose which of 3 next steps" : nil }))
        #expect(sessions.first { $0.id == "747978a2" }?.needs == "choose which of 3 next steps")
        #expect(sessions.first { $0.id == "abc12345" }?.needs == "permission prompt")   // CLI wins
    }

    @Test("runs only when the jobs fingerprint changes or the cache is older than maxAge")
    func caches() async {
        let clock = Clock(), print = Box("a")
        let source = ClaudeAgentsSource(run: { Self.sample }, fingerprint: { print.value },
                                        fallback: { [] }, needs: { _ in nil }, maxAge: 60, now: { clock.now })
        #expect(await source.currentFresh().count == 3)
        _ = await source.currentFresh(); _ = await source.currentFresh()
        #expect(source.runCount == 1)
        print.value = "b"
        _ = await source.currentFresh()
        #expect(source.runCount == 2)
        clock.now = clock.now.addingTimeInterval(61)
        _ = await source.currentFresh()
        #expect(source.runCount == 3)
        await source.refreshNow()
        #expect(source.runCount == 4)
    }

    @Test("current() never blocks: a stale cache returns at once and refreshes behind it")
    func currentDoesNotBlock() async {
        let gate = DispatchSemaphore(value: 0)
        let source = ClaudeAgentsSource(run: { gate.wait(); return Self.sample },
                                        fingerprint: { "x" }, fallback: { [] }, needs: { _ in nil })
        #expect(source.current().isEmpty)       // returned while the run is held
        gate.signal()
        #expect(await source.currentFresh().count == 3)
        #expect(source.runCount == 1)
    }

    @Test("concurrent callers share one run")
    func singleFlight() async {
        let source = ClaudeAgentsSource(run: { Thread.sleep(forTimeInterval: 0.2); return Self.sample },
                                        fingerprint: { "x" }, fallback: { [] }, needs: { _ in nil })
        async let a = source.currentFresh()
        async let b = source.currentFresh()
        async let c = source.refreshNow()
        let results = await [a, b, c]
        #expect(results.allSatisfy { $0.count == 3 })
        #expect(source.runCount == 1)
    }

    @Test("a missing or failing CLI falls back to the jobs files")
    func fallsBack() async {
        let fallback = ClaudeBackgroundSession(id: "deadbeef", sessionID: "s", name: "from jobs")
        let source = ClaudeAgentsSource(run: { nil }, fingerprint: { "x" }, fallback: { [fallback] }, needs: { _ in nil })
        #expect(await source.currentFresh() == [fallback])
    }

    private final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
    private final class Box: @unchecked Sendable { var value: String; init(_ v: String) { value = v } }
}
