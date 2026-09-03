import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("Grok session reader")
struct GrokSessionReaderTests {

    private func updates(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: - summary.json / signals.json

    @Test("model, branch and the real context window come off the session files")
    func readsSessionFiles() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("summary.json", GrokFixture.summary())
        try fixture.write("signals.json", GrokFixture.signals)

        let info = try #require(GrokSessionReader.read(directory: fixture.directory)?.info)
        #expect(info.model == "grok-4.6")
        #expect(info.branch == "feature/fixture")
        #expect(info.contextWindow == 500_000)          // not the flat 200k default
        #expect(info.contextTokens == 80_944)
        #expect(info.summary == "stored turn recap")    // last_turn_summary fallback
    }

    @Test("an empty directory reads as nothing at all")
    func emptyDirectory() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        #expect(GrokSessionReader.read(directory: fixture.directory) == nil)
    }

    @Test("live context size from the log beats the signals snapshot")
    func liveContextWins() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("signals.json", GrokFixture.signals)
        try fixture.write("updates.jsonl", [
            GrokFixture.agentChunk("first", totalTokens: 90_000),
            GrokFixture.agentChunk("second", totalTokens: 97_500),
        ].joined(separator: "\n"))

        let info = try #require(GrokSessionReader.read(directory: fixture.directory)?.info)
        #expect(info.contextTokens == 97_500)
        #expect(info.contextWindow == 500_000)
    }

    // MARK: - Tokens

    @Test("the newest turn_completed is one turn's cost, tagged with its prompt id")
    func turnTokensFromLog() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("updates.jsonl", [
            GrokFixture.turnCompleted(input: 1_000, output: 100, promptID: "p1"),
            GrokFixture.turnCompleted(input: 2_000, output: 200, promptID: "p2"),
        ].joined(separator: "\n"))

        let info = try #require(GrokSessionReader.read(directory: fixture.directory)?.info)
        #expect(info.tokens == 2_200)
        #expect(info.tokensTurnID == "p2")   // the reducer dedupes on this, not the total
    }

    @Test("two turns of identical cost are told apart by their prompt ids")
    func equalCostTurnsKeepDistinctIDs() {
        let first = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.turnCompleted(input: 1_000, output: 100, promptID: "p1"),
        ]))
        let second = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.turnCompleted(input: 1_000, output: 100, promptID: "p2"),
        ]))
        #expect(first.turnTokens == second.turnTokens)
        #expect(first.turnTokensID == "p1")
        #expect(second.turnTokensID == "p2")
    }

    @Test("without a prompt_id the record's _meta identity stands in")
    func turnIDFallsBackToMeta() {
        let facts = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.turnCompleted(input: 10, output: 1, promptID: nil,
                                      eventID: "session-1-2587"),
        ]))
        #expect(facts.turnTokens == 11)
        #expect(facts.turnTokensID == "session-1-2587")
    }

    // MARK: - Prose

    @Test("the summary is the model's newest message, not its reasoning")
    func lastAssistantProse() {
        let facts = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.userChunk("do the thing"),
            GrokFixture.thoughtChunk("private reasoning"),
            GrokFixture.agentChunk("starting now"),
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
            GrokFixture.toolDone(id: "call-1"),
            GrokFixture.agentChunk("all done"),
        ]))
        #expect(facts.lastAssistantText == "all done")
    }

    @Test("chunks of one message join")
    func joinsChunks() {
        let facts = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.userChunk("go"),
            GrokFixture.agentChunk("part one"),
            GrokFixture.agentChunk("part two"),
        ]))
        #expect(facts.lastAssistantText == "part one part two")
    }

    // MARK: - Tool state

    @Test("an unclosed tool_call is the running tool")
    func runningTool() {
        let facts = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
            GrokFixture.toolDone(id: "call-1"),
            GrokFixture.toolCall(id: "call-2", title: "run_terminal_command"),
            GrokFixture.toolProgress(id: "call-2"),   // no `status`: still running
        ]))
        #expect(facts.runningTool == "run_terminal_command")
    }

    @Test("a closed or turn-ended log reports no running tool")
    func noRunningTool() {
        let closed = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
            GrokFixture.toolDone(id: "call-1", status: "failed"),
        ]))
        #expect(closed.runningTool == nil)

        let ended = GrokSessionReader.facts(updatesTail: updates([
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
            GrokFixture.turnCompleted(input: 10, output: 1),
        ]))
        #expect(ended.runningTool == nil)
    }

    // MARK: - Permission

    @Test("an unmatched permission_requested is a waiting prompt")
    func pendingPermission() {
        let pending = GrokSessionReader.pendingPermissionTool(eventsTail: Data("""
            \(GrokFixture.permissionRequested("read_file"))
            \(GrokFixture.permissionResolved("read_file"))
            \(GrokFixture.permissionRequested("run_terminal_command"))
            """.utf8))
        #expect(pending == "run_terminal_command")
    }

    @Test("a resolved permission leaves nothing pending")
    func resolvedPermission() {
        let pending = GrokSessionReader.pendingPermissionTool(eventsTail: Data("""
            \(GrokFixture.permissionRequested("run_terminal_command"))
            \(GrokFixture.permissionResolved("run_terminal_command"))
            """.utf8))
        #expect(pending == nil)
    }

    // MARK: - Tail behaviour

    @Test("a huge updates.jsonl is read from the tail only")
    func readsOnlyTheTail() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }

        // `tool_call_update` repeats a tool's accumulated output, so real logs
        // reach gigabytes. Anything older than the window must not be reported.
        let filler = GrokFixture.agentChunk(String(repeating: "x", count: 900))
        var lines = [
            GrokFixture.subagentSpawned(id: "ancient", type: "explore", detail: "Long gone"),
            GrokFixture.turnCompleted(input: 999_999, output: 999_999),
        ]
        lines.append(contentsOf: Array(repeating: filler, count: 1_400))   // > 1 MB
        lines.append(GrokFixture.userChunk("newest prompt"))
        lines.append(GrokFixture.agentChunk("newest reply", totalTokens: 12_345))
        lines.append(GrokFixture.turnCompleted(input: 700, output: 30))
        try fixture.write("updates.jsonl", lines.joined(separator: "\n"))

        let size = try FileManager.default
            .attributesOfItem(atPath: fixture.directory.appendingPathComponent("updates.jsonl").path)[.size] as? Int
        #expect((size ?? 0) > GrokSessionReader.updatesTailBytes)

        let snapshot = try #require(GrokSessionReader.read(directory: fixture.directory))
        let info = snapshot.info
        #expect(info.tokens == 730)              // the old giant turn scrolled out
        #expect(info.contextTokens == 12_345)
        #expect(info.summary == "newest reply")

        let entries = GrokSessionReader.recentEntries(directory: fixture.directory, limit: 3)
        #expect(entries.last == TranscriptEntry(role: "assistant", text: "newest reply"))

        // A record older than the window is genuinely never seen.
        #expect(snapshot.subagents.isEmpty)
    }

    @Test("one tool record bigger than the events window still leaves the turn readable")
    func oversizedToolRecord() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }

        // A single `tool_call_update` carries the tool's accumulated output and
        // routinely passes 256 KB. When it is the newest record, a window that
        // small holds no complete line at all and the pane comes up empty.
        try fixture.write("updates.jsonl", [
            GrokFixture.userChunk("do the thing"),
            GrokFixture.agentChunk("newest reply", totalTokens: 4_242),
            GrokFixture.toolCall(id: "call-1", title: "run_terminal_command"),
            GrokFixture.update(#"""
                {"sessionUpdate":"tool_call_update","toolCallId":"call-1","status":"completed",\#
                "rawOutput":{"stdout":"\#(String(repeating: "z", count: 400_000))"}}
                """#),
        ].joined(separator: "\n"))

        let info = try #require(GrokSessionReader.read(directory: fixture.directory)?.info)
        // Everything before the oversized record is still in the window.
        #expect(info.contextTokens == 4_242)
        #expect(info.activeTool == nil)          // the big record closed the call

        let entries = GrokSessionReader.recentEntries(directory: fixture.directory)
        #expect(entries.map(\.text) == ["do the thing", "newest reply", "⚙ run_terminal_command"])
    }

    // MARK: - Subagents

    @Test("subagents come from their meta.json and from the log")
    func subagentsFromMetaAndLog() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.writeSubagentMeta(id: "child-a", """
            {"subagent_id":"child-a","parent_session_id":"s","child_session_id":"child-a",\
            "subagent_type":"code-reviewer","description":"Review the diff","status":"completed",\
            "started_at":"2026-09-02T13:00:00.000000Z","completed_at":"2026-09-02T13:05:00.000000Z",\
            "duration_ms":300000,"tool_calls":9,"turns":1,"child_cwd":"/Users/fixture/Projects/demo app"}
            """)
        try fixture.write("updates.jsonl", [
            GrokFixture.subagentSpawned(id: "child-a", type: "code-reviewer", detail: "Review the diff"),
            GrokFixture.subagentFinished(id: "child-a"),
            GrokFixture.subagentSpawned(id: "child-b", type: "explore", detail: "Find the callers"),
        ].joined(separator: "\n"))

        let children = try #require(GrokSessionReader.read(directory: fixture.directory)).subagents
        #expect(children.count == 2)
        let a = try #require(children.first { $0.id == "child-a" })
        #expect(a.type == "code-reviewer")
        #expect(a.finished)
        let b = try #require(children.first { $0.id == "child-b" })
        #expect(b.type == "explore")
        #expect(b.detail == "Find the callers")
        #expect(b.finished == false)          // spawned, never finished
    }

    @Test("a subagent that only the log knows about is still reported")
    func subagentWithoutMeta() throws {
        let fixture = try GrokFixture()
        defer { fixture.cleanUp() }
        try fixture.write("updates.jsonl",
                          GrokFixture.subagentSpawned(id: "child-c", type: "explore", detail: "Scan"))
        let children = try #require(GrokSessionReader.read(directory: fixture.directory)).subagents
        #expect(children.map(\.id) == ["child-c"])
        #expect(children[0].finished == false)
    }

    // MARK: - Recent entries

    @Test("recent entries interleave prompts, prose and tool markers")
    func recentEntries() {
        let entries = GrokSessionReader.recentEntries(updatesTail: updates([
            GrokFixture.userChunk("do the thing"),
            GrokFixture.thoughtChunk("reasoning is not shown"),
            GrokFixture.agentChunk("on it"),
            GrokFixture.toolCall(id: "call-1", title: "read_file"),
            GrokFixture.toolDone(id: "call-1"),
            GrokFixture.agentChunk("done the thing"),
        ]))
        #expect(entries.map(\.role) == ["user", "assistant", "assistant", "assistant"])
        #expect(entries.map(\.text) == ["do the thing", "on it", "⚙ read_file", "done the thing"])
    }

    @Test("recent entries keep only the last N and truncate each")
    func recentEntryLimits() {
        let entries = GrokSessionReader.recentEntries(updatesTail: updates([
            GrokFixture.userChunk("one"),
            GrokFixture.toolCall(id: "c1", title: "grep"),
            GrokFixture.agentChunk(String(repeating: "y", count: 50)),
        ]), limit: 2, perEntryLimit: 10)
        #expect(entries.map(\.text) == ["⚙ grep", String(repeating: "y", count: 10)])
    }
}
