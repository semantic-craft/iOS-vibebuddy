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

    @Test("tracked appends are debounced and delivered without one-second scans")
    func eventDrivenDebouncedAppend() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-live.jsonl",
            lines: [
                sessionMeta(id: "desktop-live"),
                taskStarted(id: "turn-1"),
            ]
        )
        let recorder = EventRecorder(firstEventDelay: .milliseconds(300))
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(2),
            debounceInterval: .milliseconds(80)
        )
        let task = Task { await monitor.run { await recorder.append($0) } }
        defer { task.cancel() }

        #expect(await eventually { await monitor.diagnostics().watchedFileCount == 1 })
        let baseline = await monitor.diagnostics()
        #expect(baseline.discoveryPassCount == 1)

        try append(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#, to: file)
        try await Task.sleep(for: .milliseconds(20))
        try append(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"ok"}}"#, to: file)
        try await Task.sleep(for: .milliseconds(20))
        try append(taskComplete(id: "turn-1"), to: file)

        #expect(await eventually(timeout: .seconds(1)) { await recorder.count == 4 })
        let events = await recorder.events
        #expect(events.map(\.kind) == [.userPromptSubmit, .preToolUse, .postToolUse, .stop])
        let afterAppend = await monitor.diagnostics()
        #expect(afterAppend.discoveryPassCount == 1)
        #expect(afterAppend.debouncedRefreshCount == 1)

        try await Task.sleep(for: .seconds(1))
        #expect(await monitor.diagnostics().discoveryPassCount == 1)

        task.cancel()
        await task.value
    }

    @Test("incremental cursor preserves a partial JSONL line across appends")
    func incrementalCursor() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-partial.jsonl",
            lines: [sessionMeta(id: "desktop-partial"), taskStarted(id: "turn-1")]
        )
        let monitor = CodexRolloutMonitor(root: fixture.root)
        #expect(await monitor.poll(now: now).count == 1)

        let record = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#
        let split = record.index(record.startIndex, offsetBy: record.count / 2)
        try append(String(record[..<split]), to: file, newline: false)
        #expect(await monitor.poll(now: now).isEmpty)
        try append(String(record[split...]), to: file)

        let events = await monitor.poll(now: now)
        #expect(events.count == 1)
        #expect(events.first?.kind == .preToolUse)
        #expect(events.first?.toolName == "exec")
    }

    @Test("slow discovery finds a rollout created after monitoring starts")
    func discoversNewRollout() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let recorder = EventRecorder()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .milliseconds(100),
            debounceInterval: .milliseconds(20)
        )
        let task = Task { await monitor.run { await recorder.append($0) } }
        defer { task.cancel() }
        #expect(await eventually { await monitor.diagnostics().discoveryPassCount == 1 })

        _ = try fixture.write(
            named: "rollout-discovered.jsonl",
            lines: [sessionMeta(id: "desktop-new"), taskStarted(id: "turn-new")]
        )

        #expect(await eventually(timeout: .seconds(1)) { await recorder.count == 1 })
        #expect(await recorder.events.first?.sessionID == "desktop-new")
        #expect(await monitor.diagnostics().watchedFileCount == 1)

        task.cancel()
        await task.value
    }

    @Test("cursor resets after truncation and atomic replacement")
    func truncationAndReplacement() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-reset.jsonl",
            lines: [sessionMeta(id: "desktop-old"), taskStarted(id: "turn-old")]
        )
        let monitor = CodexRolloutMonitor(root: fixture.root)
        #expect(await monitor.poll(now: now).first?.sessionID == "desktop-old")

        let truncated = ([
            sessionMeta(id: "desktop-truncated", cwd: "/a/much/longer/project/path"),
            taskStarted(id: "turn-truncated"),
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"new"}}"#,
        ].joined(separator: "\n") + "\n")
        try Data(truncated.utf8).write(to: file, options: [])
        let afterTruncation = await monitor.poll(now: now)
        #expect(afterTruncation.count == 1)
        #expect(afterTruncation.first?.sessionID == "desktop-truncated")
        #expect(afterTruncation.first?.kind == .preToolUse)

        let replacement = ([
            sessionMeta(id: "desktop-replaced"),
            taskStarted(id: "turn-replaced"),
        ].joined(separator: "\n") + "\n")
        try Data(replacement.utf8).write(to: file, options: .atomic)
        let afterReplacement = await monitor.poll(now: now)
        #expect(afterReplacement.count == 1)
        #expect(afterReplacement.first?.sessionID == "desktop-replaced")
    }

    @Test("discovery spans the current and previous local day")
    func crossDayDiscovery() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-today.jsonl",
            lines: [sessionMeta(id: "desktop-today"), taskStarted(id: "today")]
        )
        _ = try fixture.write(
            named: "rollout-yesterday.jsonl",
            lines: [sessionMeta(id: "desktop-yesterday"), taskStarted(id: "yesterday")],
            daysAgo: 1
        )

        let monitor = CodexRolloutMonitor(root: fixture.root)
        let ids = Set(await monitor.poll(now: now).map(\.sessionID))
        #expect(ids == ["desktop-today", "desktop-yesterday"])
    }

    @Test("daemon restart bootstraps an already-active rollout")
    func daemonRestart() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-restart.jsonl",
            lines: [sessionMeta(id: "desktop-restart"), taskStarted(id: "turn-1")]
        )

        let first = CodexRolloutMonitor(root: fixture.root)
        #expect(await first.poll(now: now).first?.sessionID == "desktop-restart")
        let restarted = CodexRolloutMonitor(root: fixture.root)
        #expect(await restarted.poll(now: now).first?.sessionID == "desktop-restart")
    }

    @Test("an invalidated watcher is recreated and continues tailing")
    func watcherRecovery() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-recovery.jsonl",
            lines: [sessionMeta(id: "desktop-recovery"), taskStarted(id: "turn-1")]
        )
        let recorder = EventRecorder()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(5),
            debounceInterval: .milliseconds(20)
        )
        let task = Task { await monitor.run { await recorder.append($0) } }
        defer { task.cancel() }
        #expect(await eventually { await monitor.diagnostics().watchedFileCount == 1 })

        await monitor.invalidateWatcherForTesting(at: file)
        #expect(await eventually { await monitor.diagnostics().watcherRecoveryCount >= 1 })
        try append(taskComplete(id: "turn-1"), to: file)

        #expect(await eventually(timeout: .seconds(1)) { await recorder.count == 2 })
        #expect(await recorder.events.last?.kind == .stop)

        task.cancel()
        await task.value
    }

    @Test("cancelling monitoring releases watcher descriptors and child tasks")
    func cancellationReleasesResources() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-cancel.jsonl",
            lines: [sessionMeta(id: "desktop-cancel"), taskStarted(id: "turn-1")]
        )
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(5),
            debounceInterval: .milliseconds(100)
        )
        let task = Task { await monitor.run { _ in } }
        #expect(await eventually { await monitor.diagnostics().watchedFileCount == 1 })

        task.cancel()
        await task.value

        let diagnostics = await monitor.diagnostics()
        #expect(!diagnostics.isRunning)
        #expect(!diagnostics.recoveryTaskRunning)
        #expect(!diagnostics.deliveryTaskRunning)
        #expect(diagnostics.watchedFileCount == 0)
        #expect(diagnostics.pendingDebounceCount == 0)
        #expect(diagnostics.queuedEventCount == 0)
    }

    @Test("server shutdown joins the rollout monitor")
    func serverShutdownReleasesMonitor() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-server.jsonl",
            lines: [sessionMeta(id: "desktop-server"), taskStarted(id: "turn-1")]
        )
        let monitor = CodexRolloutMonitor(root: fixture.root)
        let server = VibeBuddyServer(
            store: SessionStore(), token: "monitor-lifecycle", port: 0,
            codexRolloutMonitor: monitor
        )
        let serverTask = Task { try await server.runService() }
        #expect(await eventually { await monitor.diagnostics().watchedFileCount == 1 })

        serverTask.cancel()
        _ = await serverTask.result

        #expect(await eventually {
            let diagnostics = await monitor.diagnostics()
            return !diagnostics.isRunning
                && !diagnostics.recoveryTaskRunning
                && !diagnostics.deliveryTaskRunning
                && diagnostics.watchedFileCount == 0
                && diagnostics.pendingDebounceCount == 0
                && diagnostics.queuedEventCount == 0
        })
    }

    @Test("shutdown joins an already queued recovery before final cleanup")
    func queuedRecoveryCannotReinstallWatcher() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-recovery-race.jsonl",
            lines: [sessionMeta(id: "desktop-race"), taskStarted(id: "turn-1")]
        )
        let gate = RecoveryGate()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .milliseconds(20)
        )
        await monitor.setRecoveryGateForTesting { await gate.wait() }
        let task = Task { await monitor.run { _ in } }
        #expect(await eventually { await monitor.diagnostics().watchedFileCount == 1 })
        #expect(await eventually { await gate.hasEntered })

        task.cancel()
        #expect(await eventually {
            let diagnostics = await monitor.diagnostics()
            return !diagnostics.isRunning && diagnostics.recoveryTaskRunning
        })
        await gate.open()
        await task.value
        try await Task.sleep(for: .milliseconds(50))

        let diagnostics = await monitor.diagnostics()
        #expect(diagnostics.discoveryPassCount == 1)
        #expect(!diagnostics.isRunning)
        #expect(!diagnostics.recoveryTaskRunning)
        #expect(!diagnostics.deliveryTaskRunning)
        #expect(diagnostics.watchedFileCount == 0)
        #expect(diagnostics.pendingDebounceCount == 0)
        #expect(diagnostics.queuedEventCount == 0)
    }
}

private actor EventRecorder {
    private(set) var events: [HookEvent] = []
    private let firstEventDelay: Duration?
    private var isFirstEvent = true
    var count: Int { events.count }

    init(firstEventDelay: Duration? = nil) {
        self.firstEventDelay = firstEventDelay
    }

    func append(_ event: HookEvent) async {
        if isFirstEvent {
            isFirstEvent = false
            if let firstEventDelay { try? await Task.sleep(for: firstEventDelay) }
        }
        events.append(event)
    }
}

private actor RecoveryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var hasEntered = false
    private var isOpen = false

    func wait() async {
        hasEntered = true
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private struct RolloutFixture {
    let root: URL
    let now: Date

    init(now: Date) throws {
        self.now = now
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(named name: String, lines: [String], daysAgo: Int = 0) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func sessionMeta(id: String, cwd: String = "/x/project") -> String {
    #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"Codex Desktop","source":"vscode"}}"#
}

private func taskStarted(id: String) -> String {
    #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(id)"}}"#
}

private func taskComplete(id: String) -> String {
    #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"\#(id)","last_agent_message":"Done"}}"#
}

private func append(_ line: String, to file: URL, newline: Bool = true) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line + (newline ? "\n" : "")).utf8))
}

private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
