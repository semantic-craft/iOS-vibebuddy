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

    /// The real installer, into a support directory whose path has a space
    /// and an apostrophe; a known Claude version instead of spawning Claude.
    private func installer(home: URL) -> HookInstaller {
        HookInstaller(environment: HookInstallerEnvironment(
            home: home, supportDirectory: home.appendingPathComponent("support with space's"),
            variables: ["GROK_HOME": home.appendingPathComponent(".grok").path],
            claudeVersion: { ClaudeCodeVersion(2, 1, 257) }),
            scriptSource: root.appendingPathComponent("hooks"))
    }

    private func install(home: URL, approval: Bool) throws {
        let settings = home.appendingPathComponent(".claude/settings.json")
        if !FileManager.default.fileExists(atPath: settings.path) {
            try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo user-hook"}]}]}}"#.utf8).write(to: settings)
        }
        for directory in [".codex", ".grok"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        // Hooks only: the status line stays an explicit, separate action.
        let before = try Data(contentsOf: settings)
        let report = installer(home: home).install([.claude, .codex, .grok], approval: approval)
        #expect(report.failures == 0, "\(report.text)")
        if var root = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any],
           let original = try JSONSerialization.jsonObject(with: before) as? [String: Any],
           original["statusLine"] == nil {
            root["statusLine"] = nil
            try JSONSerialization.data(withJSONObject: root).write(to: settings)
        }
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
        #expect(installer(home: home).enableStatusLine().failures == 0)
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
