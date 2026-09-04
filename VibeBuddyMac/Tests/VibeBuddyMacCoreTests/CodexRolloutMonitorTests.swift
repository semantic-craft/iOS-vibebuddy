import Foundation
import Testing
import VibeBuddyKit
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

        let call = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"function_call","namespace":"docs","name":"search","call_id":"c1"}}"#.utf8), receivedAt: now)
        #expect(call?.kind == .preToolUse)
        #expect(call?.toolName == "docs/search")

        let output = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#.utf8), receivedAt: now)
        #expect(output?.kind == .postToolUse)

        let customOutput = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c2","output":"ok"}}"#.utf8), receivedAt: now)
        #expect(customOutput?.kind == .postToolUse)
    }

    @Test("a tool call after probe retirement re-arms parser activity")
    func toolCallRearmsAfterAbandon() {
        var parser = CodexRolloutParser()
        _ = parser.parseLine(Data(sessionMeta(id: "thread-1").utf8), receivedAt: now)
        _ = parser.parseLine(Data(taskStarted(id: "turn-1").utf8), receivedAt: now)
        #expect(parser.turnActive)
        parser.abandonActiveTurns()
        #expect(!parser.turnActive)

        let call = parser.parseLine(Data(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#.utf8), receivedAt: now)
        #expect(call?.kind == .preToolUse)
        #expect(parser.turnActive)
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

    @Test("a spawned subagent thread is folded, never surfaced as its own session")
    func subagentRolloutIsSkipped() {
        var parser = CodexRolloutParser()
        let meta = #"{"type":"session_meta","payload":{"id":"child-1","cwd":"/x/project","originator":"Codex Desktop","parent_thread_id":"thread-1","thread_source":"subagent","source":{"subagent":{"thread_spawn":{"parent_thread_id":"thread-1","agent_path":"/root/research"}}}}}"#
        #expect(parser.parseEvents(Data(meta.utf8), receivedAt: now).isEmpty)
        #expect(!parser.isDesktopSession)
        #expect(parser.parseEvents(Data(taskStarted(id: "turn-1").utf8), receivedAt: now).isEmpty)
    }

    @Test("turn_context and token_count enrich model and context without moving progress")
    func usageEnrichment() {
        var parser = CodexRolloutParser()
        var reducer = SessionReducer()
        let lines = [
            sessionMeta(id: "thread-1"),
            taskStarted(id: "turn-1"),
            turnContext(model: "gpt-5.6-sol"),
            tokenCount(lastTotal: 170_674, reasoning: 4_385, cumulative: 500_000, window: 258_400),
        ]
        var events: [HookEvent] = []
        for line in lines {
            for event in parser.parseEvents(Data(line.utf8), receivedAt: now) {
                events.append(event)
                reducer.apply(event)
                if let enrichment = event.enrichment {
                    reducer.enrich(sessionID: event.sessionID, with: enrichment)
                }
            }
        }
        #expect(events.map(\.kind) == [.userPromptSubmit, .sessionMetadataChanged, .sessionMetadataChanged])
        #expect(events[1].model == "gpt-5.6-sol")
        #expect(events[2].enrichment?.tokens == 170_674)
        #expect(events[2].enrichment?.contextTokens == 166_289)
        #expect(events[2].enrichment?.contextWindow == 258_400)
        let session = reducer.sessions["thread-1"]
        #expect(session?.status == .working)
        #expect(session?.model == "gpt-5.6-sol")
        #expect(session?.contextTokens == 166_289)
        #expect(session?.contextWindow == 258_400)
        #expect(session?.spentTokens == 170_674)

        // The same model again is not news; a switch is.
        #expect(parser.parseEvents(Data(turnContext(model: "gpt-5.6-sol").utf8), receivedAt: now).isEmpty)
        #expect(parser.parseEvents(Data(turnContext(model: "gpt-5.6-mini").utf8), receivedAt: now).first?.model == "gpt-5.6-mini")
    }

    @Test("usage bookkeeping never surfaces an idle desktop thread")
    func usageDoesNotSurfaceIdleThreads() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let idle = try fixture.write(
            named: "rollout-idle.jsonl",
            lines: [sessionMeta(id: "desktop-idle"), taskStarted(id: "t1"), taskComplete(id: "t1")]
        )
        let working = try fixture.write(
            named: "rollout-working.jsonl",
            lines: [sessionMeta(id: "desktop-working"), taskStarted(id: "t1")]
        )
        let monitor = CodexRolloutMonitor(root: fixture.root)
        #expect(await monitor.poll(now: now).map(\.sessionID) == ["desktop-working"])

        try append(tokenCount(lastTotal: 10, reasoning: 0, cumulative: 10, window: 100), to: idle)
        try append(tokenCount(lastTotal: 20, reasoning: 0, cumulative: 20, window: 100), to: working)
        let events = await monitor.poll(now: now)
        #expect(events.map(\.sessionID) == ["desktop-working"])
        #expect(events.first?.kind == .sessionMetadataChanged)
        #expect(events.first?.enrichment?.tokens == 20)
    }

    @Test("bootstrap restores the model and cumulative spend of an active turn")
    func bootstrapRestoresUsage() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-active.jsonl",
            lines: [
                sessionMeta(id: "desktop-active"),
                turnContext(model: "gpt-5.6-sol"),
                taskStarted(id: "t1"),
                tokenCount(lastTotal: 100, reasoning: 10, cumulative: 100, window: 1_000),
                taskComplete(id: "t1"),
                taskStarted(id: "t2"),
                tokenCount(lastTotal: 300, reasoning: 0, cumulative: 400, window: 1_000),
            ]
        )
        let monitor = CodexRolloutMonitor(root: fixture.root)
        let events = await monitor.poll(now: now)
        #expect(events.map(\.kind) == [.userPromptSubmit, .sessionMetadataChanged])
        #expect(events.last?.model == "gpt-5.6-sol")
        #expect(events.last?.enrichment?.tokens == 400)
        #expect(events.last?.enrichment?.contextTokens == 300)
        #expect(events.last?.enrichment?.contextWindow == 1_000)
    }

    @Test("an ownerless Desktop thread leaves working within a minute")
    func ownerlessThreadLeavesWorking() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-ownerless.jsonl",
            lines: [sessionMeta(id: "desktop-ownerless"), taskStarted(id: "t1")]
        )
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            isDesktopAppServerAlive: { false },
            hasWriterLock: { _ in false }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-ownerless"]?.status == .working)

        for event in await monitor.poll(now: now.addingTimeInterval(59)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-ownerless"]?.status == .working)
        #expect(reducer.sessions["desktop-ownerless"]?.summary != "Abandoned")

        for event in await monitor.poll(now: now.addingTimeInterval(60)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-ownerless"]?.status == .done)
        #expect(reducer.sessions["desktop-ownerless"]?.summary == "Abandoned")
        #expect(reducer.sessions["desktop-ownerless"]?.failed != true)
    }

    @Test("worst-case scan phase still abandons within a minute of the writer vanishing")
    func worstCaseScanPhaseLeavesWorkingWithinAMinute() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-phase.jsonl",
            lines: [sessionMeta(id: "desktop-phase"), taskStarted(id: "t1")]
        )
        let discoveryInterval: TimeInterval = 30
        let ownerlessAfter: TimeInterval = 60
        let writer = WriterFlag(isAlive: true)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(discoveryInterval),
            ownerlessAfter: ownerlessAfter,
            isDesktopAppServerAlive: { writer.isAlive },
            hasWriterLock: { _ in writer.isAlive }
        )

        // t=0: last scan that still sees a writer. The writer vanishes immediately after.
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-phase"]?.status == .working)
        writer.isAlive = false

        // Production cadence: first ownerless observation is one interval later.
        let firstOwnerless = now.addingTimeInterval(discoveryInterval)
        for event in await monitor.poll(now: firstOwnerless) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-phase"]?.status == .working)
        #expect(reducer.sessions["desktop-phase"]?.summary != "Abandoned")

        // Bound is ownerlessAfter from the last owned scan, not from first ownerless.
        // The old clock would still be waiting until firstOwnerless + ownerlessAfter (90s).
        let deadline = now.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: deadline) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-phase"]?.status == .done)
        #expect(reducer.sessions["desktop-phase"]?.summary == "Abandoned")
        #expect(reducer.sessions["desktop-phase"]?.failed != true)
    }

    @Test("writer vanishes, ChatGPT relaunches inside the grace, the interrupted turn still retires within a minute")
    func relaunchInsideGraceStillRetires() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-relaunch.jsonl",
            lines: [sessionMeta(id: "desktop-relaunch"), taskStarted(id: "t1")]
        )
        let discoveryInterval: TimeInterval = 30
        let ownerlessAfter: TimeInterval = 60
        let appServer = WriterFlag(isAlive: true)
        let lock = WriterFlag(isAlive: true)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(discoveryInterval),
            ownerlessAfter: ownerlessAfter,
            isDesktopAppServerAlive: { appServer.isAlive },
            hasWriterLock: { _ in lock.isAlive }
        )

        // t=0: last scan that still sees a writer.
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-relaunch"]?.status == .working)

        // ChatGPT quits; the interrupted thread's lock file is leftover.
        appServer.isAlive = false
        let firstOwnerless = now.addingTimeInterval(discoveryInterval)
        for event in await monitor.poll(now: firstOwnerless) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-relaunch"]?.status == .working)
        #expect(reducer.sessions["desktop-relaunch"]?.summary != "Abandoned")

        // Relaunch inside the grace: new app-server is alive, stale lock remains.
        // That pair is not fresh thread evidence and must not reset the clock.
        appServer.isAlive = true
        let beforeDeadline = now.addingTimeInterval(ownerlessAfter - 1)
        for event in await monitor.poll(now: beforeDeadline) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-relaunch"]?.status == .working)
        #expect(reducer.sessions["desktop-relaunch"]?.summary != "Abandoned")

        let deadline = now.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: deadline) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-relaunch"]?.status == .done)
        #expect(reducer.sessions["desktop-relaunch"]?.summary == "Abandoned")
        #expect(reducer.sessions["desktop-relaunch"]?.failed != true)
    }

    @Test("ChatGPT relaunch between scans still retires the interrupted turn within a minute")
    func appServerReplacementBetweenScansRetires() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-replaced.jsonl",
            lines: [sessionMeta(id: "desktop-replaced"), taskStarted(id: "t1")]
        )
        let discoveryInterval: TimeInterval = 30
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 11)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(discoveryInterval),
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentity: { server.current },
            hasWriterLock: { _ in true }
        )

        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-replaced"]?.status == .working)

        // Quit and relaunch entirely between scans: both observations see a live
        // app-server plus leftover lock. Identity change is the missing edge.
        server.relaunch()
        let firstAfterReplace = now.addingTimeInterval(discoveryInterval)
        for event in await monitor.poll(now: firstAfterReplace) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-replaced"]?.status == .working)
        #expect(reducer.sessions["desktop-replaced"]?.summary != "Abandoned")

        let deadline = now.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: deadline) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-replaced"]?.status == .done)
        #expect(reducer.sessions["desktop-replaced"]?.summary == "Abandoned")
        #expect(reducer.sessions["desktop-replaced"]?.failed != true)
    }

    @Test("a rollout append in the same pass as an app-server replacement stays owned")
    func appendDuringAppServerReplacementStaysOwned() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-replaced-live.jsonl",
            lines: [sessionMeta(id: "desktop-replaced-live"), taskStarted(id: "t1")]
        )
        let discoveryInterval: TimeInterval = 30
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 21)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(discoveryInterval),
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentity: { server.current },
            hasWriterLock: { _ in true }
        )

        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-replaced-live"]?.status == .working)

        try append(
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#,
            to: file)
        server.relaunch()
        let afterReplace = now.addingTimeInterval(discoveryInterval)
        for event in await monitor.poll(now: afterReplace) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-replaced-live"]?.status == .working)
        #expect(reducer.sessions["desktop-replaced-live"]?.activeTool == "exec")
        #expect(reducer.sessions["desktop-replaced-live"]?.summary != "Abandoned")

        let deadline = now.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: deadline) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-replaced-live"]?.status == .working)
        #expect(reducer.sessions["desktop-replaced-live"]?.summary != "Abandoned")
    }

    @Test("when the owning app-server exits during overlap, the interrupted turn still retires")
    func owningServerExitDuringOverlapRetires() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-overlap-exit.jsonl",
            lines: [sessionMeta(id: "desktop-overlap-exit"), taskStarted(id: "t1")]
        )
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 71)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentities: { server.identities },
            hasWriterLock: { _ in true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-exit"]?.status == .working)

        server.overlap(pid: 72, startedAt: now.addingTimeInterval(1))
        for event in await monitor.poll(now: now.addingTimeInterval(30)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-exit"]?.status == .working)

        server.dropOldest()
        for event in await monitor.poll(now: now.addingTimeInterval(90)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-exit"]?.status == .done)
        #expect(reducer.sessions["desktop-overlap-exit"]?.summary == "Abandoned")
    }

    @Test("a rollout bootstrapped during overlap stays owned after the old server exits")
    func rolloutBootstrappedDuringOverlapStaysOwned() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 81)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentities: { server.identities },
            hasWriterLock: { _ in true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }

        server.overlap(pid: 82, startedAt: now.addingTimeInterval(1))
        _ = try fixture.write(
            named: "rollout-overlap-boot.jsonl",
            lines: [sessionMeta(id: "desktop-overlap-boot"), taskStarted(id: "t1")]
        )
        for event in await monitor.poll(now: now.addingTimeInterval(30)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-boot"]?.status == .working)

        server.dropOldest()
        for event in await monitor.poll(now: now.addingTimeInterval(90)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-boot"]?.status == .working)
        #expect(reducer.sessions["desktop-overlap-boot"]?.summary != "Abandoned")
    }

    @Test("a rollout written before the overlapping replacement is discovered still retires")
    func rolloutWrittenBeforeOverlapDiscoveryRetires() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 91)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentities: { server.identities },
            hasWriterLock: { _ in true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }

        let writtenAt = now.addingTimeInterval(10)
        let file = try fixture.write(
            named: "rollout-overlap-stale.jsonl",
            lines: [sessionMeta(id: "desktop-overlap-stale"), taskStarted(id: "t1")]
        )
        try FileManager.default.setAttributes([.modificationDate: writtenAt], ofItemAtPath: file.path)
        server.overlap(pid: 92, startedAt: now.addingTimeInterval(20))
        for event in await monitor.poll(now: now.addingTimeInterval(30)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-stale"]?.status == .working)

        server.dropOldest()
        for event in await monitor.poll(now: now.addingTimeInterval(90)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap-stale"]?.status == .done)
        #expect(reducer.sessions["desktop-overlap-stale"]?.summary == "Abandoned")
    }

    @Test("an overlapping replacement process does not abandon a turn that wrote during the overlap")
    func overlappingAppServerAppendStaysOwned() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-overlap.jsonl",
            lines: [sessionMeta(id: "desktop-overlap"), taskStarted(id: "t1")]
        )
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 61)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentities: { server.identities },
            hasWriterLock: { _ in true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap"]?.status == .working)

        try append(
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#,
            to: file)
        server.overlap(pid: 62, startedAt: Date())
        let watcherNow = Date()
        for event in await monitor.consumeForTesting(file: file, now: watcherNow) { reducer.apply(event) }
        server.dropOldest()

        let laterScan = watcherNow.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: laterScan) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-overlap"]?.status == .working)
        #expect(reducer.sessions["desktop-overlap"]?.summary != "Abandoned")
    }

    @Test("a watcher append under a replacement server stays owned across the next scan")
    func watcherAppendUnderReplacementStaysOwned() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-watcher-replace.jsonl",
            lines: [sessionMeta(id: "desktop-watcher-replace"), taskStarted(id: "t1")]
        )
        let ownerlessAfter: TimeInterval = 60
        let server = IdentityFlag(pid: 51)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            ownerlessAfter: ownerlessAfter,
            desktopAppServerIdentity: { server.current },
            hasWriterLock: { _ in true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-watcher-replace"]?.status == .working)

        try append(
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#,
            to: file)
        server.relaunch()
        let watcherNow = Date()
        for event in await monitor.consumeForTesting(file: file, now: watcherNow) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-watcher-replace"]?.activeTool == "exec")

        let laterScan = watcherNow.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: laterScan) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-watcher-replace"]?.status == .working)
        #expect(reducer.sessions["desktop-watcher-replace"]?.summary != "Abandoned")
    }

    @Test("a rollout append after an ownerless scan re-arms ownership")
    func rolloutAppendRearmsOwnership() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-rearm.jsonl",
            lines: [sessionMeta(id: "desktop-rearm"), taskStarted(id: "t1")]
        )
        let discoveryInterval: TimeInterval = 30
        let ownerlessAfter: TimeInterval = 60
        let appServer = WriterFlag(isAlive: true)
        let lock = WriterFlag(isAlive: true)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(discoveryInterval),
            ownerlessAfter: ownerlessAfter,
            isDesktopAppServerAlive: { appServer.isAlive },
            hasWriterLock: { _ in lock.isAlive }
        )

        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)

        appServer.isAlive = false
        let firstOwnerless = now.addingTimeInterval(discoveryInterval)
        for event in await monitor.poll(now: firstOwnerless) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)
        #expect(reducer.sessions["desktop-rearm"]?.summary != "Abandoned")

        try append(
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#,
            to: file)
        appServer.isAlive = true
        let rearmedAt = firstOwnerless.addingTimeInterval(1)
        for event in await monitor.poll(now: rearmedAt) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)
        #expect(reducer.sessions["desktop-rearm"]?.activeTool == "exec")

        // Without the append, the original deadline would have retired this turn.
        let originalDeadline = now.addingTimeInterval(ownerlessAfter)
        for event in await monitor.poll(now: originalDeadline) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)
        #expect(reducer.sessions["desktop-rearm"]?.summary != "Abandoned")

        for event in await monitor.poll(now: originalDeadline.addingTimeInterval(discoveryInterval)) {
            reducer.apply(event)
        }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)
        #expect(reducer.sessions["desktop-rearm"]?.summary != "Abandoned")
    }

    @Test("a tool output after approval clears waiting so a later quit can retire")
    func toolOutputClearsWaitingAndAllowsRetirement() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-approved.jsonl",
            lines: [
                sessionMeta(id: "desktop-approved"),
                taskStarted(id: "t1"),
                #"{"type":"event_msg","payload":{"type":"exec_approval_request"}}"#,
            ]
        )
        let writer = WriterFlag(isAlive: true)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            isDesktopAppServerAlive: { writer.isAlive },
            hasWriterLock: { _ in writer.isAlive }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-approved"]?.status == .needsResponse)

        try append(
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#,
            to: file)
        for event in await monitor.poll(now: now.addingTimeInterval(1)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-approved"]?.status == .working)

        writer.isAlive = false
        for event in await monitor.poll(now: now.addingTimeInterval(61)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-approved"]?.status == .done)
        #expect(reducer.sessions["desktop-approved"]?.summary == "Abandoned")
    }

    @Test("a probe-retired turn that resumes with a tool can retire again")
    func resumedAbandonedTurnCanRetireAgain() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-rearm.jsonl",
            lines: [sessionMeta(id: "desktop-rearm"), taskStarted(id: "t1")]
        )
        let writer = WriterFlag(isAlive: true)
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            isDesktopAppServerAlive: { writer.isAlive },
            hasWriterLock: { _ in writer.isAlive }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)

        writer.isAlive = false
        for event in await monitor.poll(now: now.addingTimeInterval(60)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .done)
        #expect(reducer.sessions["desktop-rearm"]?.summary == "Abandoned")

        writer.isAlive = true
        try append(
            #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"c1"}}"#,
            to: file)
        for event in await monitor.poll(now: now.addingTimeInterval(61)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .working)
        #expect(reducer.sessions["desktop-rearm"]?.probeRetired != true)

        writer.isAlive = false
        for event in await monitor.poll(now: now.addingTimeInterval(121)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-rearm"]?.status == .done)
        #expect(reducer.sessions["desktop-rearm"]?.summary == "Abandoned")
    }

    @Test("bootstrapping after ChatGPT already relaunched retires the interrupted turn")
    func bootstrapAfterAppServerReplacementRetires() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let file = try fixture.write(
            named: "rollout-stale-server.jsonl",
            lines: [sessionMeta(id: "desktop-stale-server"), taskStarted(id: "t1")]
        )
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let server = IdentityFlag(pid: 41, startedAt: now.addingTimeInterval(3600))
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            desktopAppServerIdentity: { server.current },
            hasWriterLock: { _ in true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-stale-server"]?.status == .working)

        for event in await monitor.poll(now: now.addingTimeInterval(60)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-stale-server"]?.status == .done)
        #expect(reducer.sessions["desktop-stale-server"]?.summary == "Abandoned")
        #expect(reducer.sessions["desktop-stale-server"]?.failed != true)
    }

    @Test("a Desktop turn waiting for input is not abandoned when the writer vanishes")
    func waitingTurnIsNotAbandoned() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-waiting.jsonl",
            lines: [
                sessionMeta(id: "desktop-waiting"),
                taskStarted(id: "t1"),
                #"{"type":"event_msg","payload":{"type":"exec_approval_request"}}"#,
            ]
        )
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            isDesktopAppServerAlive: { false },
            hasWriterLock: { _ in false }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-waiting"]?.status == .needsResponse)

        for event in await monitor.poll(now: now.addingTimeInterval(60)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-waiting"]?.status == .needsResponse)
        #expect(reducer.sessions["desktop-waiting"]?.summary != "Abandoned")
    }

    @Test("an owned but silent Desktop rollout stays working")
    func ownedSilentRolloutStaysWorking() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-silent.jsonl",
            lines: [sessionMeta(id: "desktop-silent"), taskStarted(id: "t1")]
        )
        let discoveryInterval: TimeInterval = 30
        let ownerlessAfter: TimeInterval = 60
        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            discoveryInterval: .seconds(discoveryInterval),
            ownerlessAfter: ownerlessAfter,
            isDesktopAppServerAlive: { true },
            hasWriterLock: { _ in true }
        )

        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-silent"]?.status == .working)

        for step in 1...3 {
            for event in await monitor.poll(now: now.addingTimeInterval(discoveryInterval * TimeInterval(step))) {
                reducer.apply(event)
            }
        }
        #expect(reducer.sessions["desktop-silent"]?.status == .working)
        #expect(reducer.sessions["desktop-silent"]?.summary != "Abandoned")
    }

    @Test("an unreadable lock directory does not abandon a live Desktop writer")
    func unreadableLockDirectoryKeepsWorking() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/09/02", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-lockunreadable.jsonl")
        try Data(( [sessionMeta(id: "desktop-lockunreadable"), taskStarted(id: "t1")]
            .joined(separator: "\n") + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let lockDir = home.appendingPathComponent("thread-writer-locks", isDirectory: true)
        try FileManager.default.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: lockDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                        ofItemAtPath: lockDir.path) }

        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: sessions,
            isDesktopAppServerAlive: { true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-lockunreadable"]?.status == .working)

        for event in await monitor.poll(now: now.addingTimeInterval(60)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-lockunreadable"]?.status == .working)
        #expect(reducer.sessions["desktop-lockunreadable"]?.summary != "Abandoned")
    }

    @Test("a missing lock directory does not abandon a live Desktop writer")
    func missingLockDirectoryKeepsWorking() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-nolockdir.jsonl",
            lines: [sessionMeta(id: "desktop-nolockdir"), taskStarted(id: "t1")]
        )
        let siblingLocks = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("thread-writer-locks", isDirectory: true)
        #expect(!FileManager.default.fileExists(atPath: siblingLocks.path))

        var reducer = SessionReducer()
        let monitor = CodexRolloutMonitor(
            root: fixture.root,
            isDesktopAppServerAlive: { true }
        )
        for event in await monitor.poll(now: now) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-nolockdir"]?.status == .working)

        for event in await monitor.poll(now: now.addingTimeInterval(60)) { reducer.apply(event) }
        #expect(reducer.sessions["desktop-nolockdir"]?.status == .working)
        #expect(reducer.sessions["desktop-nolockdir"]?.summary != "Abandoned")
    }

    @Test("a thread resumed from an older date directory is discovered")
    func resumedOldThreadDiscovery() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-old.jsonl",
            lines: [sessionMeta(id: "desktop-old"), taskStarted(id: "old")],
            daysAgo: 12
        )
        let stale = try fixture.write(
            named: "rollout-stale.jsonl",
            lines: [sessionMeta(id: "desktop-stale"), taskStarted(id: "stale")],
            daysAgo: 12
        )
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-3 * 60 * 60)], ofItemAtPath: stale.path)

        let monitor = CodexRolloutMonitor(root: fixture.root)
        #expect(await monitor.poll(now: now).map(\.sessionID) == ["desktop-old"])
    }

    @Test("archiving a rollout ends the session it surfaced")
    func archivedRolloutEndsSession() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        let active = try fixture.write(
            named: "rollout-active.jsonl",
            lines: [sessionMeta(id: "desktop-active"), taskStarted(id: "t1")]
        )
        let monitor = CodexRolloutMonitor(root: fixture.root)
        #expect(await monitor.poll(now: now).map(\.kind) == [.userPromptSubmit])

        try FileManager.default.removeItem(at: active)
        let ended = await monitor.poll(now: now)
        #expect(ended.map(\.kind) == [.sessionEnd])
        #expect(ended.first?.sessionID == "desktop-active")
        #expect(await monitor.poll(now: now).isEmpty)
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

    @Test("reliable spawn/send/wait/stop attach named children to the parent task")
    func collaborationReliableIdentity() {
        var parser = CodexRolloutParser()
        var reducer = SessionReducer()
        apply([
            sessionMeta(id: "thread-1"),
            taskStarted(id: "turn-1"),
            collabCall(name: "spawn_agent", callID: "c-a", arguments: #"{"task_name":"reviewer","agent_type":"worker"}"#),
            collabOutput(callID: "c-a", output: #"{"task_name":"/root/reviewer"}"#),
            collabCall(name: "spawn_agent", callID: "c-b", arguments: #"{"task_name":"explorer","agent_type":"researcher"}"#),
            collabCall(name: "send_message", callID: "c-send", arguments: #"{"target":"reviewer"}"#),
            collabItem(tool: "wait", status: "completed", callID: "c-wait-named",
                       receiverAgents: ["explorer"]),
            collabCall(name: "interrupt_agent", callID: "c-stop", arguments: #"{"target":"reviewer"}"#),
        ], parser: &parser, reducer: &reducer)

        let session = reducer.sessions["thread-1"]
        #expect(session?.status == .working)
        #expect(session?.agent == .codex)
        let ids = Set(session?.childAgents?.map(\.id) ?? [])
        #expect(ids == ["task:reviewer", "task:explorer"])
        #expect(session?.childAgents?.contains { $0.id.contains("project") } != true)
        let reviewer = session?.childAgents?.first { $0.id == "task:reviewer" }
        let explorer = session?.childAgents?.first { $0.id == "task:explorer" }
        #expect(reviewer?.kind == .task)
        #expect(reviewer?.name == "reviewer")
        #expect(reviewer?.type == "worker")
        #expect(reviewer?.status == .completed)
        #expect(explorer?.status == .completed)
        #expect(explorer?.name == "explorer")
        #expect(session?.runningChildAgentCount == 0)
        #expect(session?.childTopologyDegraded != true)
        #expect(ToolActivity.childSummary(for: session!)?.contains("reviewer") == true
                || ToolActivity.childSummary(for: session!)?.contains("explorer") == true
                || ToolActivity.childSummary(for: session!)?.contains("finished") == true)
    }

    @Test("missing identity or wait-any end signal is unknown/degraded, never guessed running or done")
    func collaborationUnknownAndDegraded() {
        var parser = CodexRolloutParser()
        var reducer = SessionReducer()
        apply([
            sessionMeta(id: "thread-1", cwd: "/x/secret-project"),
            taskStarted(id: "turn-1"),
            collabCall(name: "spawn_agent", callID: "c-anon", arguments: #"{"agent_type":"default"}"#),
            collabOutput(callID: "c-anon", output: #"{"ok":true}"#),
        ], parser: &parser, reducer: &reducer)

        let afterAnon = reducer.sessions["thread-1"]
        #expect(afterAnon?.childTopologyDegraded == true)
        #expect(afterAnon?.childAgents?.isEmpty != false || afterAnon?.childAgents == nil)
        #expect(afterAnon?.childAgents?.contains { $0.id.contains("secret-project") } != true)
        #expect(afterAnon?.runningChildAgentCount == 0)

        var named = SessionReducer()
        var namedParser = CodexRolloutParser()
        apply([
            sessionMeta(id: "thread-1"),
            taskStarted(id: "turn-1"),
            collabCall(name: "spawn_agent", callID: "c-a", arguments: #"{"task_name":"alpha"}"#),
            collabCall(name: "spawn_agent", callID: "c-b", arguments: #"{"task_name":"beta"}"#),
            collabCall(name: "wait_agent", callID: "c-wait", arguments: #"{"timeout_ms":120000}"#),
            collabItem(tool: "wait", status: "completed", callID: "c-wait",
                       receiverAgents: []),
            collabOutput(callID: "c-wait", output: #"{"message":"Wait completed.","timed_out":false}"#),
        ], parser: &namedParser, reducer: &named)

        let session = named.sessions["thread-1"]
        #expect(session?.childTopologyDegraded == true)
        #expect(Set(session?.childAgents?.map(\.id) ?? []) == ["task:alpha", "task:beta"])
        #expect(session?.childAgents?.allSatisfy { $0.status == .unknown } == true)
        #expect(session?.runningChildAgentCount == 0)
        #expect(session?.childAgents?.contains { $0.status == .completed } != true)
        #expect(ToolActivity.childSummary(for: session!)?.contains("Unknown") == true
                || ToolActivity.childSummary(for: session!)?.contains("unknown") == true)
    }

    @Test("parent turn ending first does not invent child completion")
    func collaborationParentTurnEndsFirst() {
        var parser = CodexRolloutParser()
        var reducer = SessionReducer()
        apply([
            sessionMeta(id: "thread-1"),
            taskStarted(id: "turn-1"),
            collabCall(name: "spawn_agent", callID: "c-a", arguments: #"{"task_name":"alpha"}"#),
            collabCall(name: "spawn_agent", callID: "c-b", arguments: #"{"task_name":"beta"}"#),
            taskComplete(id: "turn-1"),
        ], parser: &parser, reducer: &reducer)

        let session = reducer.sessions["thread-1"]
        #expect(session?.status == .done)
        #expect(session?.activeTool == nil)
        #expect(Set(session?.childAgents?.map(\.id) ?? []) == ["task:alpha", "task:beta"])
        #expect(session?.childAgents?.allSatisfy { $0.status == .running } == true)
        #expect(session?.runningChildAgentCount == 2)
    }

    @Test("daemon mid-start restores running collab children even after the parent turn ended")
    func collaborationBootstrapMidStart() async throws {
        let fixture = try RolloutFixture(now: now)
        defer { fixture.remove() }
        _ = try fixture.write(
            named: "rollout-collab.jsonl",
            lines: [
                sessionMeta(id: "desktop-collab"),
                taskStarted(id: "turn-1"),
                collabCall(name: "spawn_agent", callID: "c-a", arguments: #"{"task_name":"alpha"}"#),
                collabCall(name: "spawn_agent", callID: "c-b", arguments: #"{"task_name":"beta"}"#),
                taskComplete(id: "turn-1"),
            ]
        )

        let monitor = CodexRolloutMonitor(root: fixture.root)
        var reducer = SessionReducer()
        for event in await monitor.poll(now: now) { reducer.apply(event) }

        let session = reducer.sessions["desktop-collab"]
        #expect(session?.status == .done)
        #expect(Set(session?.childAgents?.map(\.id) ?? []) == ["task:alpha", "task:beta"])
        #expect(session?.childAgents?.allSatisfy { $0.status == .running } == true)
        #expect(session?.runningChildAgentCount == 2)
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

/// Flip the injected writer probes mid-test without capturing a local `var`.
private final class WriterFlag: @unchecked Sendable {
    var isAlive: Bool
    init(isAlive: Bool) { self.isAlive = isAlive }
}

private final class IdentityFlag: @unchecked Sendable {
    var identities: [CodexDesktopAppServer.Identity]
    var current: CodexDesktopAppServer.Identity? {
        get { identities.first }
        set { identities = newValue.map { [$0] } ?? [] }
    }
    init(pid: pid_t, startedAt: Date = Date(timeIntervalSince1970: 0)) {
        identities = [Self.identity(pid: pid, startedAt: startedAt)]
    }
    func relaunch(startedAt: Date = Date(timeIntervalSince1970: 0)) {
        let next = (current?.pid ?? 0) + 1
        identities = [Self.identity(pid: next, startedAt: startedAt)]
    }
    func overlap(pid: pid_t, startedAt: Date) {
        identities.append(Self.identity(pid: pid, startedAt: startedAt))
    }
    func dropOldest() {
        if identities.count > 1 { identities.removeFirst() }
    }
    private static func identity(pid: pid_t, startedAt: Date) -> CodexDesktopAppServer.Identity {
        let sec = UInt64(max(0, startedAt.timeIntervalSince1970.rounded(.down)))
        return CodexDesktopAppServer.Identity(pid: pid, startSec: sec, startUsec: 0)
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

private func apply(
    _ lines: [String],
    parser: inout CodexRolloutParser,
    reducer: inout SessionReducer
) {
    for line in lines {
        for event in parser.parseEvents(Data(line.utf8), receivedAt: Date(timeIntervalSince1970: 1_788_314_400)) {
            reducer.apply(event)
        }
    }
}

private func collabCall(name: String, callID: String, arguments: String) -> String {
    let escaped = arguments.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"type":"response_item","payload":{"type":"function_call","namespace":"collaboration","name":"\#(name)","call_id":"\#(callID)","arguments":"\#(escaped)"}}"#
}

private func collabOutput(callID: String, output: String) -> String {
    let escaped = output.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"\#(callID)","output":"\#(escaped)"}}"#
}

private func collabItem(
    tool: String,
    status: String,
    callID: String,
    receiverAgents: [String]
) -> String {
    let agents = receiverAgents.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CollabAgentToolCall","id":"\#(callID)","tool":"\#(tool)","status":"\#(status)","sender_thread_id":"thread-1","receiver_thread_ids":[],"receiver_agents":[\#(agents)],"agents_states":{}}}}"#
}

private func sessionMeta(id: String, cwd: String = "/x/project") -> String {
    #"{"type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","originator":"Codex Desktop","source":"vscode"}}"#
}

private func taskStarted(id: String) -> String {
    #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"\#(id)"}}"#
}

private func turnContext(model: String) -> String {
    #"{"type":"turn_context","payload":{"turn_id":"t","cwd":"/x/project","model":"\#(model)","approval_policy":"never"}}"#
}

private func tokenCount(lastTotal: Int, reasoning: Int, cumulative: Int, window: Int) -> String {
    #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(cumulative)},"last_token_usage":{"input_tokens":1,"output_tokens":1,"reasoning_output_tokens":\#(reasoning),"total_tokens":\#(lastTotal)},"model_context_window":\#(window)},"rate_limits":null}}"#
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
