import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Grok session enrichment wiring")
struct GrokSessionStoreTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func hook(_ event: String, _ fixture: GrokFixture, extra: String = "") -> Data {
        Data("""
            {"hookEventName":"\(event)","sessionId":"\(fixture.sessionID)",\
            "cwd":"\(fixture.cwd)","workspaceRoot":"\(fixture.cwd)"\(extra)}
            """.utf8)
    }

    /// The reported health of grok's hook source in the live snapshot.
    private func hookHealth(_ store: SessionStore, at now: Date) async -> ObservationHealth? {
        await store.snapshot(now: now).observationDiagnostics?
            .first { $0.agent == .grok }?
            .sources.first { $0.source == .hook }?.health
    }

    private func populated() throws -> GrokFixture {
        let fixture = try GrokFixture()
        try fixture.write("summary.json", GrokFixture.summary(id: fixture.sessionID, cwd: fixture.cwd))
        try fixture.write("signals.json", GrokFixture.signals)
        try fixture.write("updates.jsonl", [
            GrokFixture.userChunk("do the thing"),
            GrokFixture.agentChunk("on it"),
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
            GrokFixture.toolDone(id: "call-1"),
            GrokFixture.agentChunk("done the thing", totalTokens: 120_000),
            GrokFixture.turnCompleted(input: 5_000, output: 400),
        ].joined(separator: "\n"))
        return fixture
    }

    @Test("a grok hook event enriches the session from its session directory")
    func enrichesFromSessionDirectory() async throws {
        let fixture = try populated()
        defer { fixture.cleanUp() }

        let store = SessionStore(grokHome: fixture.home)
        await store.ingest(hook("session_start", fixture), agent: .grok, receivedAt: t0)

        let session = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(session.agent == .grok)
        #expect(session.model == "grok-4.6")
        #expect(session.branch == "feature/fixture")
        #expect(session.summary == "done the thing")
        #expect(session.tokens == 5_400)
        #expect(session.spentTokens == 5_400)
        #expect(session.contextTokens == 120_000)
        #expect(session.contextWindow == 500_000)     // grok's real window, not 200k
        #expect(session.observations?.contains { $0.source == .transcript } == true)
    }

    @Test("a hook-supplied transcript path names updates.jsonl, not the directory")
    func resolvesFromTranscriptPath() async throws {
        let fixture = try populated()
        defer { fixture.cleanUp() }
        let path = fixture.directory.appendingPathComponent("updates.jsonl").path

        // An empty grok home proves the path — not the locator — resolved it.
        let store = SessionStore(grokHome: URL(fileURLWithPath: NSTemporaryDirectory()))
        await store.ingest(
            hook("session_start", fixture, extra: #","transcriptPath":"\#(path)""#),
            agent: .grok, receivedAt: t0)

        let session = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(session.model == "grok-4.6")
        #expect(session.contextWindow == 500_000)
    }

    @Test("recent transcript for a grok session comes from its updates log")
    func recentTranscriptDispatches() async throws {
        let fixture = try populated()
        defer { fixture.cleanUp() }

        let store = SessionStore(grokHome: fixture.home)
        await store.ingest(hook("session_start", fixture), agent: .grok, receivedAt: t0)

        let entries = await store.recentTranscript(sessionID: fixture.sessionID)
        #expect(entries.map(\.role) == ["user", "assistant", "assistant", "assistant"])
        #expect(entries.map(\.text) == ["do the thing", "on it", "⚙ read_file", "done the thing"])
    }

    @Test("the parent's own record of its subagents becomes child topology")
    func childTopology() async throws {
        let fixture = try populated()
        defer { fixture.cleanUp() }
        try fixture.writeSubagentMeta(id: "child-a", """
            {"subagent_id":"child-a","parent_session_id":"\(fixture.sessionID)",\
            "child_session_id":"child-a","subagent_type":"code-reviewer",\
            "description":"Review the diff","status":"running",\
            "started_at":"2026-09-02T13:00:00.000000Z","tool_calls":3,"turns":1}
            """)

        let store = SessionStore(grokHome: fixture.home)
        await store.ingest(hook("session_start", fixture), agent: .grok, receivedAt: t0)

        let session = try #require(await store.snapshot(now: t0).sessions.first)
        let child = try #require(session.childAgents?.first)
        #expect(child.id == "subagent:child-a")     // same identity GrokParser mints
        #expect(child.kind == .subagent)
        #expect(child.type == "code-reviewer")
        #expect(child.status == .running)
        #expect(session.runningChildAgentCount == 1)
    }

    @Test("a session directory that does not exist enriches nothing and does not crash")
    func missingDirectory() async throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }

        let store = SessionStore(grokHome: fixture.home)
        await store.ingest(hook("session_start", fixture), agent: .grok, receivedAt: t0)

        let session = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(session.model == nil)
        #expect(session.contextWindow == nil)
        let entries = await store.recentTranscript(sessionID: fixture.sessionID)
        #expect(entries.isEmpty)
    }

    @Test("re-reading the same turn does not double the session spend")
    func cumulativeSpendIsNotDoubled() {
        var reducer = SessionReducer()
        reducer.apply(HookEvent(kind: .sessionStart, sessionID: "s", agent: .grok, timestamp: t0))
        // Every mid-turn event re-reads the same newest `turn_completed`.
        let info = TranscriptInfo(model: "grok-4.6", tokens: 5_400,
                                  contextTokens: 80_944, contextWindow: 500_000)
        reducer.enrich(sessionID: "s", with: info)
        reducer.enrich(sessionID: "s", with: info)
        #expect(reducer.sessions["s"]?.spentTokens == 5_400)

        // The next turn's reading is a fresh cost and accumulates.
        reducer.enrich(sessionID: "s", with: TranscriptInfo(tokens: 900, contextTokens: 81_000))
        #expect(reducer.sessions["s"]?.spentTokens == 6_300)
        #expect(reducer.sessions["s"]?.tokens == 900)
    }

    @Test("a grok session teardown leaves the hook source healthy, garbage does not")
    func teardownDoesNotReportAnUnknownVersion() async throws {
        let fixture = try populated()
        defer { fixture.cleanUp() }
        // Diagnostics age against wall-clock time, so this one runs on it.
        let now = Date()
        let store = SessionStore(diagnosticsHome: fixture.home, grokHome: fixture.home)
        await store.ingest(hook("session_start", fixture), agent: .grok, receivedAt: now)

        // Fires at EVERY grok session exit, and is deliberately not a status event.
        let ignored = await store.ingest(hook("stop", fixture, extra: #","reason":"shutdown""#),
                                         agent: .grok, receivedAt: now)
        #expect(ignored == false)
        #expect(await hookHealth(store, at: now) == .healthy)

        let decoded = await store.ingest(Data("{not a hook".utf8), agent: .grok, receivedAt: now)
        #expect(decoded == false)
        #expect(await hookHealth(store, at: now) == .unknownVersion)
    }

    @Test("the session directory never rewinds a child the hooks already stopped")
    func directoryDoesNotResurrectAStoppedChild() async throws {
        let fixture = try populated()
        defer { fixture.cleanUp() }
        // `SubagentStop` fires before the child's teardown rewrites meta.json, so
        // the directory still says "running" for a child that is already done.
        try fixture.writeSubagentMeta(id: "child-a", """
            {"subagent_id":"child-a","parent_session_id":"\(fixture.sessionID)",\
            "child_session_id":"child-a","subagent_type":"explore",\
            "description":"Survey","status":"running",\
            "started_at":"2026-09-02T13:00:00.000000Z","tool_calls":3,"turns":1}
            """)

        let store = SessionStore(grokHome: fixture.home)
        await store.ingest(hook("session_start", fixture), agent: .grok, receivedAt: t0)
        await store.ingest(Data("""
            {"hookEventName":"subagent_stop","sessionId":"child-a","subagentId":"child-a",\
            "subagentType":"explore","phase":"gate"}
            """.utf8), agent: .grok, receivedAt: t0.addingTimeInterval(1))
        #expect(await store.snapshot(now: t0).sessions
            .first?.childAgents?.first?.status == .completed)

        // Any later parent event re-reads the (still stale) directory.
        await store.ingest(hook("post_tool_use", fixture, extra: #","toolName":"read_file""#),
                           agent: .grok, receivedAt: t0.addingTimeInterval(2))
        let session = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(session.childAgents?.count == 1)
        #expect(session.childAgents?.first?.status == .completed)
        #expect(session.runningChildAgentCount == 0)
    }

    @Test("a settled session never shows a tool the log still has open")
    func settledSessionShowsNoRunningTool() async throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("signals.json", GrokFixture.signals)
        // The stop gate fires before `turn_completed` is written, so the log is
        // still mid-tool when the session settles.
        try fixture.write("updates.jsonl", [
            GrokFixture.userChunk("do the thing"),
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
        ].joined(separator: "\n"))

        let store = SessionStore(grokHome: fixture.home)
        await store.ingest(hook("user_prompt_submit", fixture, extra: #","promptId":"p1""#),
                           agent: .grok, receivedAt: t0)
        // A working session with no tool of its own takes the log's opinion.
        #expect(await store.snapshot(now: t0).sessions.first?.activeTool == "read_file")

        await store.ingest(hook("stop", fixture, extra: #","promptId":"p1","reason":"end_turn""#),
                           agent: .grok, receivedAt: t0.addingTimeInterval(1))
        let done = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(done.status == .done)
        #expect(done.activeTool == nil)

        // Same for a session waiting on the user.
        await store.ingest(hook("notification", fixture,
                                extra: #","notificationType":"permission_prompt""#),
                           agent: .grok, receivedAt: t0.addingTimeInterval(2))
        let waiting = try #require(await store.snapshot(now: t0).sessions.first)
        #expect(waiting.status == .needsResponse)
        #expect(waiting.activeTool == nil)
    }
}
