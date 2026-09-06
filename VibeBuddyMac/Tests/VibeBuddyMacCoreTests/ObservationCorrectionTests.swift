import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("OH-1 installer to snapshot regressions")
struct ObservationCorrectionTests {
    private let now = Date()
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func install(home: URL, approval: Bool) throws {
        let scripts = home.appendingPathComponent("scripts with space's")
        if !FileManager.default.fileExists(atPath: scripts.path) {
            try FileManager.default.copyItem(at: root.appendingPathComponent("hooks"), to: scripts)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        // Import real installers; supply a known version instead of spawning Claude.
        process.arguments = ["-c", """
        import importlib.util, json, os, pathlib
        base = pathlib.Path(os.environ['HOME']) / "scripts with space's"
        for name in ['claude', 'codex', 'grok']:
            spec = importlib.util.spec_from_file_location(name, base / ('install-' + name + '-hooks.py'))
            m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            target = pathlib.Path(os.environ['HOME']) / {'claude':'.claude/settings.json','codex':'.codex/hooks.json','grok':'.grok/hooks/vibebuddy.json'}[name]
            target.parent.mkdir(parents=True, exist_ok=True)
            data = json.loads(target.read_text()) if target.exists() else {'hooks': {'Stop': [{'hooks':[{'command':'echo user-hook'}]}]}}
            if name == 'grok': data = m.build(approval=\(approval ? "True" : "False"))
            else:
                m.install(data\(approval ? ", approval=True" : "")) if name == 'codex' else m.install(data)
                if name == 'claude' and \(approval ? "True" : "False"): m.install_approval(data, (2,1,257))
            target.write_text(json.dumps(data))
        """]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin",
                               "GROK_HOME": home.appendingPathComponent(".grok").path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(String(decoding: output, as: UTF8.self))")
    }

    @Test("ordinary and approval installs wait, then accept partial observed coverage")
    func installerSnapshot() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh1-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for approval in [false, true] {
            try install(home: home, approval: approval)
            try install(home: home, approval: approval)
            let store = SessionStore(diagnosticsHome: home, grokHome: home.appendingPathComponent(".grok"))
            let initial = await store.snapshot(now: now)
            #expect(initial.sessions.isEmpty)
            #expect(initial.row(.claudeCode, .statusline)?.reasonCode == "optionalSourceNotConfigured")
            for agent in [AgentKind.claudeCode, .codex, .grok] {
                let hook = try #require(initial.row(agent, .hook))
                #expect(hook.health == .temporarilySilent)
                #expect(hook.reasonCode == "awaitingActivity")
                #expect(hook.lastObservedAt == nil)
                #expect(hook.configuredCoverage == ObservationEventCoverage.allCases)
                await store.ingest(HookEvent(kind: .sessionStart, sessionID: agent.rawValue,
                    agent: agent, cwd: "/test", observationSource: .hook, timestamp: now))
            }
            let active = await store.snapshot(now: now)
            for agent in [AgentKind.claudeCode, .codex, .grok] {
                #expect(active.row(agent, .hook)?.health == .healthy)
                #expect(active.row(agent, .hook)?.reasonCode == nil)
                #expect(active.row(agent, .hook)?.observedCoverage.contains(.attention) == false)
            }
            let stale = await store.snapshot(now: now.addingTimeInterval(601))
            #expect(stale.row(.codex, .hook)?.health == .temporarilySilent)
            #expect(stale.row(.codex, .hook)?.reasonCode == nil)
            #expect(stale.row(.codex, .hook)?.lastObservedAt == now)
            #expect(stale.sessions.map(\.status) == active.sessions.map(\.status))
        }
        let enable = Process()
        enable.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        enable.arguments = [home.appendingPathComponent("scripts with space's/install-claude-hooks.py").path, "--statusline"]
        enable.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        enable.standardOutput = FileHandle.nullDevice
        try enable.run(); enable.waitUntilExit()
        #expect(enable.terminationStatus == 0)
        let enabledStore = SessionStore(diagnosticsHome: home, grokHome: home.appendingPathComponent(".grok"))
        let waiting = await enabledStore.snapshot(now: now)
        #expect(waiting.row(.claudeCode, .statusline)?.health == .temporarilySilent)
        #expect(waiting.row(.claudeCode, .statusline)?.reasonCode == "awaitingActivity")
        #expect(waiting.row(.claudeCode, .statusline)?.lastObservedAt == nil)
        let sample = try #require(StatusLineSample.decode(["session_id": "statusline-only"]))
        #expect(await enabledStore.applyStatusLine(sample, at: now) == false)
        let sampled = await enabledStore.snapshot(now: now)
        #expect(sampled.row(.claudeCode, .statusline)?.health == .healthy)
        #expect(sampled.row(.claudeCode, .statusline)?.reasonCode == nil)
        #expect(sampled.sessions.isEmpty)
    }

    @Test("misleading shell text and misplaced approvals cannot supply coverage")
    func falseCommands() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh1-\(UUID())")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = home.appendingPathComponent(".codex/hooks.json")
        let events = ["SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest"]
        for command in ["echo /app/vibebuddy-forward.sh codex", "# /app/vibebuddy-forward.sh codex",
                        "/app/vibebuddy-forward.sh\ncodex", "/app/vibebuddy-forward.sh.bak codex", "/app/vibebuddy-forward.sh grok",
                        "/app/approval-hook.sh codex", "'/app/vibebuddy-forward.sh' codex; echo x"] {
            let groups = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [["command": command]]]]) })
            try JSONSerialization.data(withJSONObject: ["hooks": groups]).write(to: config)
            let result = ObservationHealthDetector.detect(home: home, signals: [], now: now,
                grokHome: home.appendingPathComponent("absent"))
            let hook = try #require(result.first { $0.agent == .codex }?.sources.first { $0.source == .hook })
            #expect(hook.reasonCode == "configurationIncomplete")
            #expect(hook.configuredCoverage == (command == "/app/approval-hook.sh codex" ? [.attention] : []))
        }
    }

    @Test("Grok passive source waits independently and preserves real read failures")
    func passiveSignals() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh1-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        func row(_ signals: [ObservationRuntimeSignal], at: Date) throws -> ObservationSourceDiagnostic {
            let rows = ObservationHealthDetector.detect(home: nil, signals: signals, now: at, grokHome: home)
            return try #require(rows.first { $0.agent == .grok }?.sources.first { $0.source == .transcript })
        }
        #expect(try row([], at: now).reasonCode == "awaitingActivity")
        let hook = ObservationRuntimeSignal(agent: .grok, source: .hook, lastObservedAt: now)
        #expect(try row([hook], at: now).lastObservedAt == nil)
        let read = ObservationRuntimeSignal(agent: .grok, source: .transcript, lastObservedAt: now)
        #expect(try row([hook, read], at: now).health == .healthy)
        #expect(try row([read], at: now.addingTimeInterval(601)).health == .temporarilySilent)
        let failure = ObservationRuntimeSignal(agent: .grok, source: .transcript, lastObservedAt: now, health: .sourceUnreadable)
        #expect(try row([failure], at: now).health == .sourceUnreadable)
        #expect(try row([failure], at: now).reasonCode == nil)
    }
}

private extension Snapshot {
    func row(_ agent: AgentKind, _ source: ObservationSource) -> ObservationSourceDiagnostic? {
        observationDiagnostics?.first { $0.agent == agent }?.sources.first { $0.source == source }
    }
}
