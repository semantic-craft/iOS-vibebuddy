import Testing
import Foundation
import SQLite3
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Cursor's hook envelope: snake_case keys, camelCase event names, keyed on
/// `conversation_id`. The payloads below are the documented field sets
/// (cursor.com/docs/hooks) rather than invented shapes.
private func cursorHook(_ event: String, extra: String = "") -> Data {
    let base = #"{"hook_event_name":"\#(event)","conversation_id":"c1","generation_id":"g1","#
        + #""model":"Claude Fable 5","cursor_version":"3.20.17","workspace_roots":["/x/p"],"#
        + #""user_email":"me@example.com","transcript_path":"/t/c1.jsonl""#
    return Data((base + extra + "}").utf8)
}

@Suite("Cursor hook adapter")
struct CursorHookAdapterTests {

    @Test func lifecycleMapsOntoTheThreeStates() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("sessionStart", extra: #","session_id":"s1","is_background_agent":false,"composer_mode":"agent""#),
                           agent: .cursor, receivedAt: now)
        var session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.agent == .cursor)
        #expect(session?.status == .done)
        #expect(session?.project.isEmpty == false)

        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"ship it""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.status == .working)
        // The prompt is carried on the event (the lifecycle journal reads it) but
        // does not become the row's line, exactly as Claude's UserPromptSubmit
        // does not. Cursor's own subtitle and the agent's reply fill that.
        #expect(session?.summary == nil)

        await store.ingest(cursorHook("preToolUse", extra: #","tool_name":"Shell","tool_input":{"command":"ls"},"cwd":"/x/p""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(2))
        session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.activeTool == "Bash")

        await store.ingest(cursorHook("stop", extra: #","status":"completed","loop_count":0"#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(3))
        session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.status == .done)
        #expect(session?.activeTool == nil)
        #expect(session?.hasUnreadCompletion == true)
        #expect(session?.failed != true)
    }

    @Test func shellAndMCPGatesReportActivityUnderCanonicalNames() {
        let shell = CursorParser.parse(cursorHook("beforeShellExecution",
            extra: #","command":"git status","cwd":"/x/p","sandbox":false"#), receivedAt: Date())
        #expect(shell.event?.kind == .preToolUse)
        #expect(shell.event?.toolName == "Bash")
        #expect(shell.event?.cwd == "/x/p")

        let mcp = CursorParser.parse(cursorHook("beforeMCPExecution",
            extra: #","tool_name":"search","mcp_server_name":"exa","tool_input":{}"#), receivedAt: Date())
        #expect(mcp.event?.toolName == "mcp__exa__search")
    }

    @Test func aFailedToolMarksTheSessionStuck() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("postToolUseFailure",
            extra: #","tool_name":"Shell","tool_input":{},"error_message":"exit 1","failure_type":"error","duration":12"#),
            agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.failed == true)
    }

    /// Cursor names an abort explicitly, which is more than Codex can do: it is
    /// an ending the person asked for, not a crash to ring the error cue for.
    @Test func anAbortedTurnIsAUserStopRatherThanAFailure() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("stop", extra: #","status":"aborted","loop_count":1"#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.status == .done)
        #expect(session?.userStopped == true)
        #expect(session?.failed != true)
        #expect(session?.hasUnreadCompletion == false)
    }

    @Test func anErroredTurnStaysAFailure() {
        let result = CursorParser.parse(cursorHook("stop", extra: #","status":"error""#), receivedAt: Date())
        #expect(result.event?.completionSucceeded == false)
        #expect(result.event?.userStopped == false)
        #expect(result.event?.message == "Turn failed")
    }

    @Test func compactionCarriesTheRealContextWindow() {
        let result = CursorParser.parse(cursorHook("preCompact",
            extra: #","trigger":"auto","context_tokens":158857,"context_window_size":256000,"message_count":40"#),
            receivedAt: Date())
        #expect(result.event?.toolName == "Context compaction")
        #expect(result.event?.enrichment?.contextTokens == 158857)
        #expect(result.event?.enrichment?.contextWindow == 256000)
    }

    @Test func subagentEventsStayTopology() {
        let start = CursorParser.parse(cursorHook("subagentStart",
            extra: #","subagent_id":"sa1","subagent_type":"explore","task":"look","parent_conversation_id":"c1""#),
            receivedAt: Date())
        #expect(start.event?.kind == .childLifecycle)
        #expect(start.event?.childID == "subagent:sa1")
        #expect(start.event?.childAction == .started)
        let stop = CursorParser.parse(cursorHook("subagentStop",
            extra: #","subagent_type":"explore","status":"completed","summary":"done""#), receivedAt: Date())
        #expect(stop.event?.childAction == .stopped)
        #expect(stop.event?.childID == "subagent:explore")
    }

    /// Cursor fires events that say nothing about progress on every session.
    /// Treating those as an unknown envelope would report the hook source as an
    /// unrecognised Cursor version after every turn.
    @Test func understoodButSilentEventsAreIgnoredNotUndecodable() {
        #expect(CursorParser.parse(cursorHook("afterAgentThought", extra: #","text":"hm","duration_ms":10"#),
                                   receivedAt: Date()) == .ignored)
        #expect(CursorParser.parse(cursorHook("workspaceOpen"), receivedAt: Date()) == .ignored)
        #expect(CursorParser.parse(cursorHook("beforeTabFileRead", extra: #","file_path":"/a""#),
                                   receivedAt: Date()) == .ignored)
    }

    @Test func aForeignPayloadIsUndecodable() {
        #expect(CursorParser.parse(Data(#"{"nothing":"useful"}"#.utf8), receivedAt: Date()) == .undecodable)
        #expect(CursorParser.parse(Data("not json".utf8), receivedAt: Date()) == .undecodable)
    }

    @Test func theAgentsLastWordBecomesTheRowsLine() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("afterAgentResponse", extra: #","text":"Shipped in three files.""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.summary == "Shipped in three files.")
        // Metadata never manufactures progress.
        #expect(session?.status == .working)
    }

    // MARK: - postToolUseFailure causes (cursor.com/docs/hooks)

    /// `is_interrupt` is the person pressing stop in Cursor. The tool did not
    /// break, so the error cue must stay silent.
    @Test func anInterruptedToolIsNotAFailure() async {
        let result = CursorParser.parse(cursorHook("postToolUseFailure",
            extra: #","tool_name":"Shell","tool_input":{"command":"swift test"},"error_message":"Command was interrupted","failure_type":"error","duration":812,"is_interrupt":true"#),
            receivedAt: Date())
        #expect(result.event?.kind == .postToolUse)
        #expect(result.event?.toolError == false)
        #expect(result.event?.userStopped == true)
        #expect(result.event?.message == "Stopped by you")

        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("postToolUseFailure",
            extra: #","tool_name":"Shell","tool_input":{},"error_message":"Command was interrupted","failure_type":"error","duration":812,"is_interrupt":true"#),
            agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.failed != true)
    }

    /// A gate saying no (Cursor's own, or the phone's Deny) is a decision, not
    /// a breakage.
    @Test func aDeniedToolIsNotAFailure() {
        let denied = CursorParser.parse(cursorHook("postToolUseFailure",
            extra: #","tool_name":"Shell","tool_input":{"command":"rm -rf build"},"error_message":"Permission denied by user","failure_type":"permission_denied","duration":3,"is_interrupt":false"#),
            receivedAt: Date())
        #expect(denied.event?.toolError == false)
        #expect(denied.event?.userStopped == false)
        #expect(denied.event?.message == "Permission denied by user")

        let bare = CursorParser.parse(cursorHook("postToolUseFailure",
            extra: #","tool_name":"Shell","tool_input":{},"failure_type":"permission_denied","duration":3,"is_interrupt":false"#),
            receivedAt: Date())
        #expect(bare.event?.message == "Denied")
    }

    @Test func aTimedOutToolIsStillAFailure() {
        let result = CursorParser.parse(cursorHook("postToolUseFailure",
            extra: #","tool_name":"Shell","tool_input":{"command":"sleep 999"},"error_message":"Timed out after 600s","failure_type":"timeout","duration":600000,"is_interrupt":false"#),
            receivedAt: Date())
        #expect(result.event?.toolError == true)
        #expect(result.event?.message == "Timed out after 600s")
    }

    // MARK: - composer_mode

    /// An Ask or Edit chat is a Q&A, not a task: it never becomes a row, never
    /// enters the three states, and its later events do not open one either —
    /// from the hook or from the transcript tailer, which keys on the same id.
    @Test func anAskModeChatNeverBecomesASession() async {
        let ask = CursorParser.parse(cursorHook("sessionStart",
            extra: #","session_id":"s1","is_background_agent":false,"composer_mode":"ask""#), receivedAt: Date())
        #expect(ask.event?.observeOnly == true)
        let edit = CursorParser.parse(cursorHook("sessionStart",
            extra: #","session_id":"s1","is_background_agent":false,"composer_mode":"edit""#), receivedAt: Date())
        #expect(edit.event?.observeOnly == true)

        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("sessionStart",
            extra: #","session_id":"s1","is_background_agent":false,"composer_mode":"ask""#),
            agent: .cursor, receivedAt: now)
        #expect(await store.snapshot(now: now).sessions.contains { $0.id == "c1" } == false)

        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"what does this do?""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        await store.ingest(cursorHook("preToolUse", extra: #","tool_name":"ReadFile","tool_input":{"path":"/a"},"cwd":"/x/p""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(2))
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "c1", agent: .cursor,
                                     cwd: "/x/p", message: "go", observationSource: .transcript,
                                     timestamp: now.addingTimeInterval(3)))
        await store.ingest(cursorHook("stop", extra: #","status":"completed","loop_count":0"#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(4))
        #expect(await store.snapshot(now: now).sessions.contains { $0.id == "c1" } == false)
        // Nothing was recorded as hook evidence for it either.
        #expect(await store.hasSession("c1") == false)

        // An Agent-mode chat in the same store is tracked as usual.
        let agent = cursorHook("sessionStart",
            extra: #","session_id":"s2","is_background_agent":false,"composer_mode":"agent""#)
            .replacingConversation(with: "c2")
        await store.ingest(agent, agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("preToolUse", extra: #","tool_name":"Shell","tool_input":{"command":"ls"},"cwd":"/x/p""#)
                               .replacingConversation(with: "c2"),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c2" }
        #expect(session?.status == .working)
        #expect(session?.activeTool == "Bash")

        // `sessionEnd` releases the id; a fresh Agent-mode start is tracked again.
        await store.ingest(cursorHook("sessionEnd", extra: #","session_id":"s1","reason":"user_closed""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(5))
        await store.ingest(cursorHook("sessionStart",
            extra: #","session_id":"s3","is_background_agent":false,"composer_mode":"agent""#),
            agent: .cursor, receivedAt: now.addingTimeInterval(6))
        #expect(await store.snapshot(now: now).sessions.contains { $0.id == "c1" })
    }

    // MARK: - model display

    /// `model_id` is the stable id, `model` the picker label; the picker's
    /// toggles ride in `model_params` and are worth a suffix.
    @Test func modelIDAndParamsRender() {
        let full = CursorParser.parse(cursorHook("beforeSubmitPrompt",
            extra: #","prompt":"go","model_id":"claude-opus-4-7","model_params":[{"id":"thinking","value":"true"},{"id":"context","value":"1m"},{"id":"effort","value":"max"}]"#),
            receivedAt: Date())
        #expect(full.event?.model == "claude-opus-4-7 (1m, max, thinking)")

        let some = CursorParser.parse(cursorHook("beforeSubmitPrompt",
            extra: #","prompt":"go","model_id":"gpt-5.5","model_params":[{"id":"thinking","value":"false"},{"id":"effort","value":"high"}]"#),
            receivedAt: Date())
        #expect(some.event?.model == "gpt-5.5 (high)")

        // No id and no params: the label alone, no parentheses.
        let bare = CursorParser.parse(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#), receivedAt: Date())
        #expect(bare.event?.model == "Claude Fable 5")
    }

    // MARK: - tool output into recent output

    /// `tool_output` is a JSON-stringified result payload for shell tools; the
    /// pane shows it as exit / stdout, and while the hooks are fresh it is what
    /// `/recent-output` serves — the transcript has no tool results at all.
    @Test func toolOutputRendersAndReachesRecentOutput() async {
        let result = CursorParser.parse(cursorHook("postToolUse",
            extra: #","tool_name":"Shell","tool_input":{"command":"swift test"},"tool_output":"{\"exitCode\":0,\"stdout\":\"All tests passed\"}","tool_use_id":"t1","cwd":"/x/p","duration":812"#),
            receivedAt: Date())
        #expect(result.event?.toolOutput == "exit 0\nAll tests passed")
        #expect(result.event?.toolError == false)

        let withErr = CursorParser.parse(cursorHook("postToolUse",
            extra: #","tool_name":"Shell","tool_input":{},"tool_output":"{\"exit_code\":1,\"stdout\":\"\",\"stderr\":\"boom\"}","tool_use_id":"t2","cwd":"/x/p","duration":1"#),
            receivedAt: Date())
        #expect(withErr.event?.toolOutput == "exit 1\nboom")

        let plain = CursorParser.parse(cursorHook("postToolUse",
            extra: #","tool_name":"ReadFile","tool_input":{"path":"/a"},"tool_output":"line one","tool_use_id":"t3","cwd":"/x/p","duration":1"#),
            receivedAt: Date())
        #expect(plain.event?.toolOutput == "line one")

        let long = String(repeating: "x", count: 700)
        let cut = CursorParser.parse(cursorHook("postToolUse",
            extra: #","tool_name":"ReadFile","tool_input":{},"tool_output":"\#(long)","tool_use_id":"t4","cwd":"/x/p","duration":1"#),
            receivedAt: Date())
        #expect(cut.event?.toolOutput?.count == 601)
        #expect(cut.event?.toolOutput?.hasSuffix("…") == true)

        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"run the tests""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("preToolUse", extra: #","tool_name":"Shell","tool_input":{"command":"swift test"},"cwd":"/x/p""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        await store.ingest(cursorHook("postToolUse",
            extra: #","tool_name":"Shell","tool_input":{"command":"swift test"},"tool_output":"{\"exitCode\":0,\"stdout\":\"All tests passed\"}","tool_use_id":"t1","cwd":"/x/p","duration":812"#),
            agent: .cursor, receivedAt: now.addingTimeInterval(2))
        await store.ingest(cursorHook("afterAgentResponse", extra: #","text":"Green.""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(3))
        let output = await store.recentOutput(sessionID: "c1")
        #expect(output.source == .hook)
        #expect(output.entries.map(\.role) == ["user", "assistant", "assistant", "assistant"])
        #expect(output.entries.map(\.text) == ["run the tests", "⚙ Bash", "exit 0\nAll tests passed", "Green."])
    }

    @Test func shellOutputReachesRecentOutput() async {
        let result = CursorParser.parse(cursorHook("afterShellExecution",
            extra: #","command":"git status","output":"On branch main\nnothing to commit","duration":40,"sandbox":false"#),
            receivedAt: Date())
        #expect(result.event?.toolOutput == "On branch main\nnothing to commit")

        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"status?""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("afterShellExecution",
            extra: #","command":"git status","output":"On branch main\nnothing to commit","duration":40,"sandbox":false"#),
            agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let output = await store.recentOutput(sessionID: "c1")
        #expect(output.entries.last?.text == "On branch main\nnothing to commit")
    }
}

private extension Data {
    /// The same documented payload for a second conversation.
    func replacingConversation(with id: String) -> Data {
        Data(String(decoding: self, as: UTF8.self)
            .replacingOccurrences(of: #""conversation_id":"c1""#, with: #""conversation_id":"\#(id)""#).utf8)
    }
}

@Suite("Cursor through Claude hooks")
struct CursorThroughClaudeHooksTests {
    /// With "Include third-party Plugins, Skills, and other configs" on, Cursor
    /// runs the Claude Code hooks in ~/.claude/settings.json with its own
    /// payload (cursor.com/docs/reference/third-party-hooks). The forwarder tags
    /// it `claude-code`; the decoder must still see one Cursor session.
    @Test func aCursorPayloadOnTheClaudeRouteIsACursorSession() {
        let payload = Data(#"{"hook_event_name":"preToolUse","conversation_id":"c1","generation_id":"g1","#
            .appending(#""model":"Claude Fable 5","cursor_version":"3.20.17","workspace_roots":["/x/p"],"#)
            .appending(#""tool_name":"Shell","tool_input":{"command":"ls"},"cwd":"/x/p"}"#).utf8)
        let result = HookDecoder.decode(payload, agent: .claudeCode, receivedAt: Date())
        #expect(result.event?.agent == .cursor)
        #expect(result.event?.sessionID == "c1")
        #expect(result.event?.kind == .preToolUse)
        #expect(result.event?.toolName == "Bash")
    }

    /// A camelCase event name alone is enough: no Claude-shape CLI spells its
    /// events that way.
    @Test func aCamelCaseEventNameWithoutAVersionStillRoutes() {
        let payload = Data(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"go"}"#.utf8)
        let result = HookDecoder.decode(payload, agent: .claudeCode, receivedAt: Date())
        #expect(result.event?.agent == .cursor)
        #expect(result.event?.kind == .userPromptSubmit)
    }

    @Test func aGenuineClaudePayloadIsUnchanged() {
        let payload = Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        let result = HookDecoder.decode(payload, agent: .claudeCode, receivedAt: Date())
        #expect(result.event?.agent == .claudeCode)
        #expect(result.event?.sessionID == "s1")
        #expect(result.event?.kind == .preToolUse)
    }
}

@Suite("Cursor tool vocabulary")
struct CursorToolVocabularyTests {
    @Test func cursorNamesBecomeTheCanonicalOnes() {
        #expect(CursorToolVocabulary.canonicalTool("Shell") == "Bash")
        #expect(CursorToolVocabulary.canonicalTool("AwaitShell") == "Bash")
        #expect(CursorToolVocabulary.canonicalTool("ReadFile") == "Read")
        #expect(CursorToolVocabulary.canonicalTool("StrReplace") == "Edit")
        #expect(CursorToolVocabulary.canonicalTool("ApplyPatch") == "Edit")
        #expect(CursorToolVocabulary.canonicalTool("Write") == "Write")
        #expect(CursorToolVocabulary.canonicalTool("Glob") == "Glob")
        #expect(CursorToolVocabulary.canonicalTool("WebSearch") == "WebSearch")
        #expect(CursorToolVocabulary.canonicalTool("Task") == "Task")
        // Unknown names pass through, which keeps the matcher at `.ask`.
        #expect(CursorToolVocabulary.canonicalTool("CallMcpTool") == "CallMcpTool")
        #expect(CursorToolVocabulary.canonicalTool("exa__search") == "mcp__exa__search")
    }

    @Test func inputsGainTheCanonicalSpelling() {
        let input = CursorToolVocabulary.canonicalInput(
            ["path": "/a/b.swift", "old_str": "x", "new_str": "y"])
        #expect(input["file_path"] as? String == "/a/b.swift")
        #expect(input["old_string"] as? String == "x")
        #expect(input["new_string"] as? String == "y")
        // Cursor's own keys are kept, not replaced.
        #expect(input["path"] as? String == "/a/b.swift")
    }

    @Test func mcpToolsAreNamespacedOnce() {
        #expect(CursorToolVocabulary.canonicalMCPTool(server: "exa", tool: "search") == "mcp__exa__search")
        #expect(CursorToolVocabulary.canonicalMCPTool(server: "exa", tool: "exa__search") == "mcp__exa__search")
        #expect(CursorToolVocabulary.canonicalMCPTool(server: "exa", tool: "mcp__exa__search") == "mcp__exa__search")
        #expect(CursorToolVocabulary.canonicalMCPTool(server: nil, tool: "search") == "mcp__search")
    }
}

@Suite("Cursor approval payloads")
struct CursorApprovalPayloadTests {
    private func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func aShellGateBecomesABashCall() {
        let call = ApprovalPayload.decode(object(
            #"{"hook_event_name":"beforeShellExecution","conversation_id":"c1","command":"rm -rf build","cwd":"/x/p","sandbox":false}"#),
            agent: .cursor)
        #expect(call.tool == "Bash")
        #expect(call.input["command"] as? String == "rm -rf build")
        #expect(call.sessionID == "c1")
        #expect(call.event == .preToolUse)
        // Cursor reports no permission mode, so nothing is invented for the card.
        #expect(call.permissionMode == nil)
        let details = ApprovalDetails.from(tool: call.tool, input: call.input)
        #expect(details.command == "rm -rf build")
        #expect(details.commandPreview == "rm -rf build")
    }

    @Test func anMCPGateIsNamespaced() {
        let call = ApprovalPayload.decode(object(
            #"{"hook_event_name":"beforeMCPExecution","conversation_id":"c1","tool_name":"search","mcp_server_name":"exa","tool_input":{"q":"x"}}"#),
            agent: .cursor)
        #expect(call.tool == "mcp__exa__search")
    }

    @Test func aToolGateUsesCursorsOwnVocabulary() {
        let call = ApprovalPayload.decode(object(
            #"{"hook_event_name":"preToolUse","conversation_id":"c1","tool_name":"StrReplace","tool_input":{"path":"/a/b.swift","old_str":"x","new_str":"y"}}"#),
            agent: .cursor)
        #expect(call.tool == "Edit")
        #expect(call.input["file_path"] as? String == "/a/b.swift")
        #expect(AllowRule.forApproval(tool: call.tool, input: call.input) == "Edit(/a/b.swift)")
    }

    @Test func aReadGateIsAReadOfThatFile() {
        let call = ApprovalPayload.decode(object(
            #"{"hook_event_name":"beforeReadFile","conversation_id":"c1","file_path":"/a/b.swift","content":"…"}"#),
            agent: .cursor)
        #expect(call.tool == "Read")
        #expect(call.input["file_path"] as? String == "/a/b.swift")
        // Read-only work is never worth a card.
        #expect(ApprovalShortCircuit.autoAllows(tool: call.tool, permissionMode: nil))
    }

}

@Suite("Cursor AskQuestion")
struct CursorAskQuestionTests {
    /// The shape Cursor writes into its own transcripts for `AskQuestion`.
    private let input: [String: Any] = [
        "title": "Configure pstack models",
        "questions": [[
            "id": "pstack_models",
            "prompt": "How should ~/.cursor/rules/pstack-models.mdc be written?",
            "options": [
                ["id": "remap-defaults", "label": "Accept the close-to-default mapping"],
                ["id": "all-inherit", "label": "Everything inherits the parent model"],
            ],
        ]],
    ]

    @Test func theQuestionBecomesAnAnswerableCard() throws {
        let question = try #require(CursorAskQuestionInput.pendingQuestion(from: input, id: "q-1"))
        #expect(question.id == "q-1")
        #expect(question.isBlocking == true)
        #expect(question.prompt.hasPrefix("How should"))
        #expect(question.items.count == 1)
        #expect(question.items[0].id == "pstack_models")
        #expect(question.items[0].header == "Configure pstack models")
        #expect(question.items[0].options.map(\.id) == ["remap-defaults", "all-inherit"])
        #expect(question.items[0].options[0].label == "Accept the close-to-default mapping")
        #expect(question.items[0].allowsOther)
    }

    @Test func aCallWithNoQuestionsIsNotACard() {
        #expect(CursorAskQuestionInput.pendingQuestion(from: ["title": "x"], id: "q") == nil)
        #expect(CursorAskQuestionInput.pendingQuestion(from: ["questions": []], id: "q") == nil)
    }

    /// Cursor has no contract for returning a tool *result* from a hook, so the
    /// answer travels in `agent_message` — the field Cursor documents for telling
    /// the model something.
    @Test func theAnswerIsPhrasedForTheModel() throws {
        let question = try #require(CursorAskQuestionInput.pendingQuestion(from: input, id: "q-1"))
        let message = try #require(CursorAskQuestionInput.agentMessage(
            question: question, answers: ["pstack_models": ["Accept the close-to-default mapping"]]))
        #expect(message.contains("vibebuddy"))
        #expect(message.contains("Accept the close-to-default mapping"))
        #expect(message.contains("do not ask again"))
        // An empty answer set is silence, not an empty instruction.
        #expect(CursorAskQuestionInput.agentMessage(question: question, answers: [:]) == nil)
        #expect(CursorAskQuestionInput.agentMessage(question: question,
                                                    answers: ["pstack_models": [""]]) == nil)
    }
}

@Suite("Cursor follow-up queue")
struct CursorFollowupQueueTests {
    @Test func aQueuedFollowUpIsHandedOverOnce() async {
        let queue = CursorFollowupQueue()
        #expect(await queue.queue(conversationID: "c1", text: "also update the README") != nil)
        #expect(await queue.peek(conversationID: "c1")?.text == "also update the README")
        #expect(await queue.take(conversationID: "c1") == "also update the README")
        // Cursor submits it itself; a second delivery would repeat the message.
        #expect(await queue.take(conversationID: "c1") == nil)
    }

    @Test func aSecondInstructionReplacesTheFirst() async {
        let queue = CursorFollowupQueue()
        await queue.queue(conversationID: "c1", text: "first")
        await queue.queue(conversationID: "c1", text: "second")
        #expect(await queue.take(conversationID: "c1") == "second")
    }

    @Test func emptyAndUnknownAreNotQueued() async {
        let queue = CursorFollowupQueue()
        #expect(await queue.queue(conversationID: "c1", text: "   ") == nil)
        #expect(await queue.queue(conversationID: "", text: "hi") == nil)
        #expect(await queue.take(conversationID: "nope") == nil)
    }

    @Test func aMessageForATurnThatNeverEndedExpires() async {
        let queue = CursorFollowupQueue(lifetime: 60)
        let start = Date()
        await queue.queue(conversationID: "c1", text: "later", now: start)
        #expect(await queue.peek(conversationID: "c1", now: start.addingTimeInterval(59)) != nil)
        #expect(await queue.take(conversationID: "c1", now: start.addingTimeInterval(61)) == nil)
    }
}

@Suite("Cursor transcripts")
struct CursorTranscriptTests {
    /// The three line shapes Cursor 3.20 actually writes, verbatim in structure.
    private let prompt = #"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Friday, Sep 4, 2026, 2:21 AM (UTC+8)</timestamp>\n<user_query>\ncheck the lid-close sleep behaviour\n</user_query>"}]}}"#
    private let work = #"{"role":"assistant","message":{"content":[{"type":"text","text":"Looking at power assertions."},{"type":"tool_use","name":"Shell","input":{"command":"pmset -g assertions","working_directory":"/x/p"}}]}}"#
    private let ended = #"{"type":"turn_ended","status":"success"}"#

    @Test func linesAreUnderstood() {
        #expect(CursorTranscripts.parse(line: prompt) == [.prompt("check the lid-close sleep behaviour")])
        #expect(CursorTranscripts.parse(line: work) == [
            .assistantText("Looking at power assertions."),
            .toolUse(name: "Shell", detail: "pmset -g assertions"),
        ])
        #expect(CursorTranscripts.parse(line: ended) == [.turnEnded(status: "success", error: nil)])
        #expect(CursorTranscripts.parse(line: #"{"type":"turn_ended","status":"aborted","error":"User aborted/interrupted manually."}"#)
            == [.turnEnded(status: "aborted", error: "User aborted/interrupted manually.")])
        #expect(CursorTranscripts.parse(line: "").isEmpty)
        #expect(CursorTranscripts.parse(line: "{").isEmpty)
    }

    @Test func aQueryWithNoWrapperIsAlreadyTheQuery() {
        #expect(CursorTranscripts.userQuery(in: "just do it") == "just do it")
        #expect(CursorTranscripts.userQuery(in: "<user_query>\n  hi \n</user_query>") == "hi")
    }

    /// Cursor flattens `/Users/me/Projects/famotype-macos` to
    /// `Users-me-Projects-famotype-macos`, which is ambiguous on paper. It is
    /// resolved against the filesystem instead of guessed.
    @Test func aFlattenedProjectNameIsResolvedAgainstDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString)")
        let hyphenated = root.appendingPathComponent("Projects/famotype-macos")
        try FileManager.default.createDirectory(at: hyphenated, withIntermediateDirectories: true)
        let flattened = String(hyphenated.path.dropFirst()).replacingOccurrences(of: "/", with: "-")
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(CursorTranscripts.projectPath(forDirectoryName: flattened) == hyphenated.path)
        #expect(CursorTranscripts.projectPath(forDirectoryName: "empty-window") == nil)
        #expect(CursorTranscripts.projectPath(forDirectoryName: flattened + "-gone") == nil)
    }

    @Test func discoveryFindsBothLayouts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcripts = root.appendingPathComponent("empty-window/agent-transcripts")
        let nested = transcripts.appendingPathComponent("aaa")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(ended.utf8).write(to: nested.appendingPathComponent("aaa.jsonl"))
        try Data(ended.utf8).write(to: transcripts.appendingPathComponent("bbb.jsonl"))

        let found = CursorTranscripts.discover(root: root)
        #expect(Set(found.map(\.conversationID)) == ["aaa", "bbb"])
        #expect(found.allSatisfy { $0.project == nil })
    }
}

@Suite("Cursor transcript tailer")
struct CursorTranscriptMonitorTests {
    private func project(_ root: URL, _ id: String) throws -> URL {
        let directory = root.appendingPathComponent("empty-window/agent-transcripts/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id).jsonl")
    }

    private func append(_ line: String, to url: URL) throws {
        let existing = (try? Data(contentsOf: url)) ?? Data()
        try (existing + Data((line + "\n").utf8)).write(to: url)
    }

    /// History is the composer store's job. A tailer that replayed what was
    /// already on disk would ring a completion for every old turn at launch.
    @Test func seedingEmitsNothing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try project(root, "c1")
        try append(#"{"role":"user","message":{"content":[{"type":"text","text":"old"}]}}"#, to: file)
        try append(#"{"type":"turn_ended","status":"success"}"#, to: file)

        let monitor = CursorTranscriptMonitor(root: root)
        #expect(await monitor.seed(now: Date()) == 1)
        #expect(await monitor.poll(now: Date()).isEmpty)
        // Compared by suffix: directory enumeration resolves the temp
        // directory's /var → /private/var symlink, and the tailer reports the
        // path it actually reads.
        #expect(await monitor.transcriptPath(for: "c1")?
            .hasSuffix("agent-transcripts/c1/c1.jsonl") == true)
    }

    @Test func appendedLinesDriveWorkingThenDone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try project(root, "c1")
        try append("", to: file)
        let monitor = CursorTranscriptMonitor(root: root)
        await monitor.seed(now: Date())

        try append(#"{"role":"user","message":{"content":[{"type":"text","text":"<user_query>go</user_query>"}]}}"#, to: file)
        try append(#"{"role":"assistant","message":{"content":[{"type":"tool_use","name":"StrReplace","input":{"path":"/a"}}]}}"#, to: file)
        var events = await monitor.poll(now: Date())
        #expect(events.map(\.kind) == [.userPromptSubmit, .preToolUse])
        #expect(events.first?.message == "go")
        #expect(events.first?.agent == .cursor)
        #expect(events.first?.observationSource == .transcript)
        #expect(events.last?.toolName == "Edit")

        try append(#"{"role":"assistant","message":{"content":[{"type":"text","text":"all set"}]}}"#, to: file)
        try append(#"{"type":"turn_ended","status":"success"}"#, to: file)
        events = await monitor.poll(now: Date())
        #expect(events.map(\.kind) == [.sessionMetadataChanged, .stop])
        #expect(events.last?.completionSucceeded == true)
        #expect(events.last?.completionText == "all set")
        // Nothing new on a third pass.
        #expect(await monitor.poll(now: Date()).isEmpty)
    }

    @Test func aHalfWrittenLineIsReadWholeOnTheNextPass() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try project(root, "c1")
        try Data("".utf8).write(to: file)
        let monitor = CursorTranscriptMonitor(root: root)
        await monitor.seed(now: Date())

        let whole = #"{"type":"turn_ended","status":"success"}"#
        try Data(String(whole.prefix(10)).utf8).write(to: file)
        #expect(await monitor.poll(now: Date()).isEmpty)
        try Data((whole + "\n").utf8).write(to: file)
        #expect(await monitor.poll(now: Date()).map(\.kind) == [.stop])
    }

    @Test func aTruncatedTranscriptStartsOver() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try project(root, "c1")
        try append(#"{"type":"turn_ended","status":"success","error":"a much longer first line"}"#, to: file)
        let monitor = CursorTranscriptMonitor(root: root)
        await monitor.seed(now: Date())
        // Shorter than what was seeded: the file was replaced, so the cursor
        // cannot mean what it did.
        try Data((#"{"type":"turn_ended","status":"error"}"# + "\n").utf8).write(to: file)
        let events = await monitor.poll(now: Date())
        #expect(events.map(\.kind) == [.stop])
        #expect(events.first?.completionSucceeded == false)
    }

    /// While the hooks are live the transcript must not move the three states:
    /// a line flushed a beat after the `stop` hook would otherwise revive a
    /// finished session and mint a second completion for the same turn.
    @Test func theTranscriptOnlyCorroboratesWhileHooksAreLive() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#),
                           agent: .cursor, receivedAt: now)
        await store.ingest(cursorHook("stop", extra: #","status":"completed""#),
                           agent: .cursor, receivedAt: now.addingTimeInterval(1))
        let completion = await store.snapshot(now: now).sessions.first { $0.id == "c1" }?.completionID

        await store.ingest(HookEvent(kind: .preToolUse, sessionID: "c1", agent: .cursor,
                                     toolName: "Bash", observationSource: .transcript,
                                     timestamp: now.addingTimeInterval(2)))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.status == .done)
        #expect(session?.completionID == completion)
        // The corroborating source is still recorded as evidence.
        #expect(session?.observations?.contains { $0.source == .transcript } == true)
    }

    @Test func theTranscriptDrivesProgressWithoutHooks() async {
        let store = SessionStore()
        let now = Date()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "c9", agent: .cursor,
                                     cwd: "/x/p", message: "go", observationSource: .transcript,
                                     timestamp: now))
        let session = await store.snapshot(now: now).sessions.first { $0.id == "c9" }
        #expect(session?.status == .working)
        #expect(session?.agent == .cursor)
    }
}

@Suite("Cursor composer store")
struct CursorComposerStoreTests {
    /// A `state.vscdb` shaped the way Cursor 3.x writes one.
    private func database(_ path: String, headers: Bool = true,
                          status: String = "completed") throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let head = #"{"type":"head","composerId":"c1","name":"Cursor plugin installation","#
            + #""subtitle":"Edited SKILL.md","contextUsagePercent":62.05,"hasBlockingPendingActions":false,"#
            + #""lastUpdatedAt":1788895069198,"createdAt":1788894888654,"#
            + #""trackedGitRepos":[{"repoPath":"/x/p","branches":[{"branchName":"main","lastInteractionAt":2}]}],"#
            + #""workspaceIdentifier":{"id":"w1","uri":{"fsPath":"/x/p","path":"/x/p","scheme":"file"}},"#
            + #""agentLocation":{"type":"local"}}"#
        let detail = #"{"composerId":"c1","status":"\#(status)","contextTokensUsed":158857,"#
            + #""contextTokenLimit":256000,"modelConfig":{"modelName":"grok-4.6"},"#
            + #""lastUpdatedAt":1788895069198,"isDraft":false}"#
        var sql = """
            CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB);
            INSERT INTO cursorDiskKV VALUES ('composerData:c1', '\(detail)');
            INSERT INTO cursorDiskKV VALUES ('bubbleId:c1:b1', '{"text":"hi"}');
            """
        if headers {
            sql += """
                CREATE TABLE composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT,
                  createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER,
                  recency INTEGER, checkpointAt INTEGER, value TEXT, subagentTypeName TEXT);
                INSERT INTO composerHeaders VALUES ('c1','w1',1788894888654,1788895069198,0,0,
                  1788895069198,NULL,'\(head)','');
                INSERT INTO composerHeaders VALUES ('sub1','w1',1,2,0,1,2,NULL,'\(head)','explore');
                """
        }
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    }

    @Test func cursorsOwnFactsAreRead() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try database(path)
        var store = CursorComposerStore(database: URL(fileURLWithPath: path))
        let composers = try #require(try store.refresh())
        // The subagent conversation is present in the database but is not a row.
        let composer = try #require(composers.first { $0.id == "c1" })
        #expect(composer.name == "Cursor plugin installation")
        #expect(composer.subtitle == "Edited SKILL.md")
        #expect(composer.project == "/x/p")
        #expect(composer.branch == "main")
        #expect(composer.model == "grok-4.6")
        #expect(composer.contextTokens == 158857)
        #expect(composer.contextWindow == 256000)
        #expect(composer.status == "completed")
        #expect(composer.isCloud == false)
        #expect(composer.hasRun)
        #expect(composers.contains { $0.isSubagent } == true)
    }

    @Test func readingNeverWritesToCursorsDatabase() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try database(path)
        let before = try Data(contentsOf: URL(fileURLWithPath: path))
        var store = CursorComposerStore(database: URL(fileURLWithPath: path))
        _ = try store.refresh()
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    }

    @Test func anUnchangedDatabaseIsNotReReadAndAMissingOneIsEmpty() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try database(path)
        var store = CursorComposerStore(database: URL(fileURLWithPath: path))
        #expect(try store.refresh() != nil)
        #expect(try store.refresh() == nil)

        var missing = CursorComposerStore(database: URL(fileURLWithPath: temporaryPath()))
        #expect(try missing.refresh()?.isEmpty == true)
    }

    /// Cursor ≤2.x keeps no `composerHeaders` table; the `composerData:` keys
    /// alone still carry enough to describe the conversation.
    @Test func theOlderLayoutStillReads() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try database(path, headers: false)
        var store = CursorComposerStore(database: URL(fileURLWithPath: path))
        let composers = try #require(try store.refresh())
        let composer = try #require(composers.first { $0.id == "c1" })
        #expect(composer.model == "grok-4.6")
        #expect(composer.contextTokens == 158857)
        #expect(composer.name == nil)
        #expect(composer.hasRun)
    }

    /// A chat the person opened and never ran has `status: "none"` and no
    /// activity — not worth a row.
    @Test func anUntouchedDraftIsNotAConversation() throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try database(path, headers: false, status: "none")
        var store = CursorComposerStore(database: URL(fileURLWithPath: path))
        let composers = try #require(try store.refresh())
        #expect(composers.first { $0.id == "c1" }?.hasRun == false)
    }

    @Test func factsFillLiveRowsAndHistoryGetsItsOwn() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try database(path)
        let store = SessionStore(cursorDatabase: URL(fileURLWithPath: path))
        let now = Date()

        // History only: no live source has ever reported this conversation.
        await store.refreshCursorComposers()
        var session = await store.snapshot(now: now).sessions.first { $0.id == "c1" }
        #expect(session?.historyOnly == true)
        #expect(session?.name == "Cursor plugin installation")
        #expect(session?.branch == "main")
        #expect(session?.contextWindow == 256000)

        // Once a hook reports it, the same facts enrich the live row instead.
        await store.ingest(cursorHook("beforeSubmitPrompt", extra: #","prompt":"go""#),
                           agent: .cursor, receivedAt: now)
        await store.refreshCursorComposers()
        let sessions = await store.snapshot(now: now).sessions.filter { $0.id == "c1" }
        #expect(sessions.count == 1)
        session = sessions.first
        #expect(session?.historyOnly == nil)
        #expect(session?.status == .working)
        #expect(session?.name == "Cursor plugin installation")
        #expect(session?.model == "grok-4.6")
        #expect(session?.contextTokens == 158857)
        #expect(session?.branch == "main")
    }
}

@Suite("Cursor CLI")
struct CursorCLITests {
    @Test func onlyRealConversationIDsReachTheShell() {
        #expect(CursorCLI.isConversationID("0e9a439b-a3a7-493f-8dc7-7d3f9149834a"))
        #expect(CursorCLI.isConversationID("bc-0e4b7540-e59e-4c94-a6f3-d344d0ba61d8"))
        #expect(!CursorCLI.isConversationID("c1"))
        #expect(!CursorCLI.isConversationID("; rm -rf /"))
        #expect(!CursorCLI.isConversationID(""))
    }

    @Test func promptsAndPathsAreQuotedForTheShell() {
        #expect(CursorCLI.shellQuoted("it's fine") == #"'it'\''s fine'"#)
        #expect(CursorCLI.command(["a", "b"], cwd: "/x/my project")
            == "cd '/x/my project' && a b")
        #expect(CursorCLI.command(["a"], cwd: nil) == "a")
    }
}

@Suite("Cursor session actions")
struct CursorSessionActionTests {
    private func session(status: SessionStatus, hooked: Bool = true) -> AgentSession {
        var session = AgentSession(id: "c1", agent: .cursor, project: "/x/p", status: status,
                                   statusSince: Date(), updatedAt: Date())
        if hooked {
            session.observations = [ObservationEvidence(source: .hook, lastObservedAt: Date(),
                                                        health: .healthy)]
        }
        return session
    }

    @Test func aRunningTurnTakesAQueuedSupplement() {
        let support = SessionActionSupport.resolve(for: session(status: .working))
        #expect(support.intent == .steer)
        #expect(support.isAvailable)
        #expect(support.note?.contains("queued") == true)
    }

    @Test func aFinishedChatContinuesThroughTheCLI() {
        let support = SessionActionSupport.resolve(for: session(status: .done))
        #expect(support.intent == .continue)
        #expect(support.isAvailable)
        #expect(support.note?.contains("terminal") == true)
    }

    @Test func withoutHooksNothingIsPromised() {
        let support = SessionActionSupport.resolve(for: session(status: .working, hooked: false))
        #expect(!support.isAvailable)
        #expect(support.unsupportedReason?.contains("Cursor hooks") == true)
    }

    @Test func cursorCannotBeStoppedFromHere() {
        let support = SessionActionSupport.resolveStop(for: session(status: .working))
        #expect(!support.isAvailable)
        #expect(support.unsupportedReason == "Stop this in Cursor on your Mac.")
    }
}
