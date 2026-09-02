import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Codex desktop rollout monitoring")
struct CodexRolloutMonitorTests {
    let now = Date(timeIntervalSince1970: 1_788_314_400) // 2026-09-02 local day

    @Test("parser maps desktop turn, tool, failure, and completion records")
    func parserLifecycle() {
        var parser = CodexRolloutParser()

        #expect(parser.parseLine(Data(#"{"timestamp":"2026-09-02T01:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/x/project","originator":"Codex Desktop","source":"vscode"}}"#.utf8), receivedAt: now) == nil)
        #expect(parser.isDesktopSession)

        let started = parser.parseLine(Data(#"{"timestamp":"2026-09-02T01:00:01Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8), receivedAt: now)
        #expect(started?.kind == .userPromptSubmit)
        #expect(started?.sessionID == "thread-1")
        #expect(started?.agent == .codex)
        #expect(started?.cwd == "/x/project")
        #expect(parser.turnActive)

        let call = parser.parseLine(Data(#"{"timestamp":"2026-09-02T01:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#.utf8), receivedAt: now)
        #expect(call?.kind == .preToolUse)
        #expect(call?.toolName == "exec")

        let failed = parser.parseLine(Data(#"{"timestamp":"2026-09-02T01:00:03Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","exit_code":1,"status":"failed"}}}"#.utf8), receivedAt: now)
        #expect(failed?.kind == .postToolUse)
        #expect(failed?.toolName == "Shell")
        #expect(failed?.toolError == true)

        let completed = parser.parseLine(Data(#"{"timestamp":"2026-09-02T01:00:04Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Tests failed"}}"#.utf8), receivedAt: now)
        #expect(completed?.kind == .stop)
        #expect(completed?.message == "Tests failed")
        #expect(!parser.turnActive)
    }

    @Test("turn_aborted becomes a failed-looking stop")
    func abortedTurn() {
        var parser = CodexRolloutParser()
        _ = parser.parseLine(Data(#"{"type":"session_meta","payload":{"id":"thread-1","cwd":"/x/project","originator":"Codex Desktop"}}"#.utf8), receivedAt: now)
        _ = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8), receivedAt: now)
        let event = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#.utf8), receivedAt: now)
        #expect(event?.kind == .stop)
        #expect(event?.message == "Turn aborted")
        #expect(!parser.turnActive)
    }

    @Test("tool outputs clear live activity for current Codex response shapes")
    func toolOutputLifecycle() {
        var parser = CodexRolloutParser()
        _ = parser.parseLine(Data(#"{"type":"session_meta","payload":{"id":"thread-1","cwd":"/x/project","originator":"Codex Desktop"}}"#.utf8), receivedAt: now)
        _ = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8), receivedAt: now)

        let call = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"function_call","namespace":"collaboration","name":"followup_task","call_id":"c1"}}"#.utf8), receivedAt: now)
        #expect(call?.kind == .preToolUse)
        #expect(call?.toolName == "collaboration/followup_task")

        let output = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#.utf8), receivedAt: now)
        #expect(output?.kind == .postToolUse)

        let customOutput = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"ok"}}"#.utf8), receivedAt: now)
        #expect(customOutput?.kind == .postToolUse)
    }

    @Test("request_user_input is attention, not background work")
    func requestUserInput() {
        var parser = CodexRolloutParser()
        _ = parser.parseLine(Data(#"{"type":"session_meta","payload":{"id":"thread-1","cwd":"/x/project","originator":"Codex Desktop"}}"#.utf8), receivedAt: now)
        _ = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8), receivedAt: now)

        let event = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"q1"}}"#.utf8), receivedAt: now)
        #expect(event?.kind == .notification)
        #expect(event?.message == "Waiting for your input")
    }

    @Test("one completed turn cannot mark a concurrently active turn done")
    func overlappingTurns() {
        var parser = CodexRolloutParser()
        _ = parser.parseLine(Data(#"{"type":"session_meta","payload":{"id":"thread-1","cwd":"/x/project","originator":"Codex Desktop"}}"#.utf8), receivedAt: now)
        _ = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-a"}}"#.utf8), receivedAt: now)
        _ = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-b"}}"#.utf8), receivedAt: now)

        let firstCompletion = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-a"}}"#.utf8), receivedAt: now)
        #expect(firstCompletion == nil)
        #expect(parser.turnActive)

        let finalCompletion = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-b","last_agent_message":"Done"}}"#.utf8), receivedAt: now)
        #expect(finalCompletion?.kind == .stop)
        #expect(!parser.turnActive)
    }

    @Test("a final answer closes a turn when task_complete is missing")
    func finalAnswerFallback() {
        var parser = CodexRolloutParser()
        _ = parser.parseLine(Data(#"{"type":"session_meta","payload":{"id":"thread-1","cwd":"/x/project","originator":"Codex Desktop"}}"#.utf8), receivedAt: now)
        _ = parser.parseLine(Data(#"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#.utf8), receivedAt: now)
        let event = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"message","role":"assistant","phase":"final_answer"}}"#.utf8), receivedAt: now)
        #expect(event?.kind == .stop)
        #expect(!parser.turnActive)
    }

    @Test("bootstrap restores only a currently active desktop turn, then tails completion")
    func bootstrapAndTail() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/09/02", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-active.jsonl")
        try Data(([
            #"{"type":"session_meta","payload":{"id":"desktop-active","cwd":"/x/project","originator":"Codex Desktop","source":"vscode"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#,
        ].joined(separator: "\n") + "\n").utf8).write(to: file)

        let monitor = CodexRolloutMonitor(root: root)
        let initial = await monitor.poll(now: now)
        #expect(initial.count == 1)
        #expect(initial.first?.sessionID == "desktop-active")
        #expect(initial.first?.kind == .preToolUse)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1","last_agent_message":"Done"}}"# + "\n").utf8))
        try handle.close()

        let appended = await monitor.poll(now: now.addingTimeInterval(1))
        #expect(appended.count == 1)
        #expect(appended.first?.kind == .stop)
        #expect(appended.first?.message == "Done")
    }

    @Test("bootstrap ignores completed desktop turns and non-desktop rollouts")
    func bootstrapFiltering() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let day = root.appendingPathComponent("2026/09/02", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)

        let completed = day.appendingPathComponent("rollout-completed.jsonl")
        try Data(([
            #"{"type":"session_meta","payload":{"id":"desktop-done","cwd":"/x/project","originator":"Codex Desktop"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Done"}}"#,
        ].joined(separator: "\n") + "\n").utf8).write(to: completed)

        let cli = day.appendingPathComponent("rollout-cli.jsonl")
        try Data(([
            #"{"type":"session_meta","payload":{"id":"cli-active","cwd":"/x/project","originator":"Codex CLI","source":"cli"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        ].joined(separator: "\n") + "\n").utf8).write(to: cli)

        let monitor = CodexRolloutMonitor(root: root)
        #expect(await monitor.poll(now: now).isEmpty)
    }
}
