import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Claude, Codex and Grok observation health diagnostics")
struct ObservationHealthDetectorTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// A `$GROK_HOME` that never exists, so a Claude or Codex test cannot reach
    /// the developer's real `~/.grok`.
    let absentGrokHome = URL(fileURLWithPath: "/nonexistent/vb-grok-absent")

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A directory path that does not exist yet; `write` creates it on demand.
    private func unwrittenDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-grok-\(UUID().uuidString)", isDirectory: true)
    }

    /// Every call goes through here so grok's home is always explicit.
    private func detect(
        home: URL?,
        grokHome: URL? = nil,
        signals: [ObservationRuntimeSignal] = [],
        staleAfter: TimeInterval = 10 * 60
    ) -> [AgentObservationDiagnostic] {
        ObservationHealthDetector.detect(
            home: home, signals: signals, now: now, staleAfter: staleAfter,
            grokHome: grokHome ?? absentGrokHome)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("missing installations are distinct from missing events")
    func missingInstallationAndEvents() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let absent = detect(home: home)
        #expect(absent.health(agent: .claudeCode, source: .hook) == .notInstalled)

        try write(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo user"}]}]}}"#,
                  to: home.appendingPathComponent(".claude/settings.json"))
        let missingEvents = detect(home: home)
        #expect(missingEvents.health(agent: .claudeCode, source: .hook) == .eventsMissing)
    }

    @Test("Codex async incompatibility is reported explicitly")
    func codexAsyncIncompatible() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        try write(#"{"hooks":{"SessionStart":[{"hooks":[{"command":"/app/vibebuddy-forward.sh codex","async":true}]}]}}"#,
                  to: home.appendingPathComponent(".codex/hooks.json"))

        let result = detect(home: home)
        #expect(result.health(agent: .codex, source: .hook) == .asyncIncompatible)
    }

    @Test("an unreadable rollout is not reported as normal")
    func unreadableRollout() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        let rollout = home.appendingPathComponent(".codex/sessions/2023/11/14/rollout-test.jsonl")
        try write(#"{"type":"session_meta","payload":{"cli_version":"1.2.3"}}"#, to: rollout)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: rollout.path)

        let result = detect(home: home)
        #expect(result.health(agent: .codex, source: .rollout) == .sourceUnreadable)
    }

    @Test("fresh, stale, and recovered signals are classified without process guesses")
    func signalFreshness() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        let old = ObservationRuntimeSignal(agent: .codex, source: .rollout,
                                           lastObservedAt: now.addingTimeInterval(-601),
                                           observedCoverage: [.turn])
        let stale = detect(home: home, signals: [old], staleAfter: 600)
        #expect(stale.health(agent: .codex, source: .rollout) == .temporarilySilent)

        let fresh = ObservationRuntimeSignal(agent: .codex, source: .rollout,
                                             lastObservedAt: now,
                                             observedCoverage: [.turn, .tool])
        let healthy = detect(home: home, signals: [fresh], staleAfter: 600)
        #expect(healthy.health(agent: .codex, source: .rollout) == .healthy)
        #expect(healthy.diagnostic(agent: .codex, source: .rollout)?.observedCoverage == [.turn, .tool])
    }

    @Test("future versions and metadata-only rollouts never synthesize healthy")
    func unsupportedOrMetadataOnly() throws {
        let futureHome = try tempHome()
        defer { try? FileManager.default.removeItem(at: futureHome) }
        try write("model = \"gpt\"\n", to: futureHome.appendingPathComponent(".codex/config.toml"))
        let future = futureHome.appendingPathComponent(".codex/sessions/2023/11/14/rollout-future.jsonl")
        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.999.0"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: future)
        let futureResult = detect(home: futureHome)
        #expect(futureResult.health(agent: .codex, source: .rollout) == .unknownVersion)

        let metadataHome = try tempHome()
        defer { try? FileManager.default.removeItem(at: metadataHome) }
        try write("model = \"gpt\"\n", to: metadataHome.appendingPathComponent(".codex/config.toml"))
        let metadata = metadataHome.appendingPathComponent(".codex/sessions/2023/11/14/rollout-metadata.jsonl")
        try write(#"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"#,
                  to: metadata)
        let metadataResult = detect(home: metadataHome)
        #expect(metadataResult.health(agent: .codex, source: .rollout) == .eventsMissing)

        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: metadata)
        let supportedResult = detect(home: metadataHome)
        #expect(supportedResult.health(agent: .codex, source: .rollout) == .healthy)
    }

    // Minimized from the H2-R Desktop rollout on 2026-09-05 (0.153.3).
    // IDs, paths, model and tool content are synthetic; no user text is retained.
    @Test("observed Desktop 0.153.3 progress is compatible even with runtime coverage")
    func desktop1533Compatibility() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rollout = home.appendingPathComponent(".codex/sessions/rollout-h2.jsonl")
        let meta = #"{"type":"session_meta","payload":{"id":"h2","cwd":"/test","originator":"Codex Desktop","source":"vscode","cli_version":"0.153.3"}}"#
        try write(meta, to: rollout)
        #expect(detect(home: home).health(agent: .codex, source: .rollout) == .eventsMissing)

        let lines = [meta,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"type":"turn_context","payload":{"model":"test-model"}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"c1","name":"exec","input":""}}"#,
            #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":""}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"turn-1"}}"#,
        ]
        var parser = CodexRolloutParser()
        let events = lines.flatMap { parser.parseEvents(Data($0.utf8), receivedAt: now) }
        #expect(events.map(\.kind) == [.userPromptSubmit, .sessionMetadataChanged,
                                      .preToolUse, .postToolUse, .stop])
        #expect(!parser.turnActive)
        try write(lines.joined(separator: "\n"), to: rollout)
        let signal = ObservationRuntimeSignal(agent: .codex, source: .rollout,
            lastObservedAt: now, observedCoverage: [.lifecycle, .turn, .tool])
        let result = detect(home: home, signals: [signal])
        #expect(result.health(agent: .codex, source: .rollout) == .healthy)
        #expect(result.diagnostic(agent: .codex, source: .rollout)?.observedCoverage
            == signal.observedCoverage)
        #expect(detect(home: home).health(agent: .codex, source: .rollout) == .healthy)

        try write(lines.joined(separator: "\n").replacingOccurrences(of: "0.153.3", with: "0.153.4"),
                  to: rollout)
        #expect(detect(home: home, signals: [signal])
            .health(agent: .codex, source: .rollout) == .unknownVersion)
    }

    @Test("bounded rollout inspection discards a partial line before decoding UTF-8")
    func boundedRolloutUTF8() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let rollout = home.appendingPathComponent(".codex/sessions/rollout-boundary.jsonl")
        let prefix = #"{"type":"session_meta","payload":{"cli_version":"0.153.3"}}"# + "\n"
            + #"{"type":"event_msg","payload":{"type":"task_started"}}"# + "\n"
        let messageStart = #"{"type":"response_item","payload":{"type":"message","text":""#
        // Like the real H2 rollouts, the 1 MiB read ends inside a valid character
        // in an incomplete record. Earlier complete records remain usable.
        let padding = String(repeating: "a", count: (1 << 20) - prefix.utf8.count
            - messageStart.utf8.count - 1)
        try write(prefix + messageStart + padding + "中" + #""}}"# + "\n", to: rollout)
        #expect(detect(home: home).health(agent: .codex, source: .rollout) == .healthy)

        // Corrupt bytes in a complete record must still fail strict decoding.
        var corrupt = Data(prefix.utf8)
        corrupt.append(contentsOf: [0xFF, 0x0A])
        try corrupt.write(to: rollout)
        #expect(detect(home: home).health(agent: .codex, source: .rollout) == .unknownVersion)
    }

    @Test("a rollout older than the recovery window still classifies as temporarily silent after a restart")
    func staleRolloutAfterRestartIsTemporarilySilent() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        let rollout = home.appendingPathComponent(".codex/sessions/2023/11/14/rollout-stale.jsonl")
        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: rollout)
        let staleAt = now.addingTimeInterval(-2 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: staleAt], ofItemAtPath: rollout.path)
        let modifiedAt = try rollout.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate

        // No runtime signal: this is an app/daemon restart. Monitor candidates
        // stay windowed — CodexRolloutMonitorTests.resumedOldThreadDiscovery
        // already asserts a 3-hour-old rollout is not tailed.
        let result = detect(home: home)
        #expect(result.health(agent: .codex, source: .rollout) == .temporarilySilent)
        #expect(result.diagnostic(agent: .codex, source: .rollout)?.lastObservedAt == modifiedAt)
    }

    @Test("a rollout still being written in an old date directory is healthy")
    func oldDateDirectoryRolloutIsHealthy() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        // `now` is 2023-11-14. The old today/yesterday walk cannot see October.
        let old = home.appendingPathComponent(".codex/sessions/2023/10/01/rollout-resumed.jsonl")
        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: old)

        let result = detect(home: home)
        #expect(result.health(agent: .codex, source: .rollout) == .healthy)
        #expect(result.diagnostic(agent: .codex, source: .rollout)?.lastObservedAt != nil)
    }

    @Test("a partial unreadable sessions tree is not classified from the accessible subset")
    func partialUnreadableSessionsTree() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        let readable = home.appendingPathComponent(".codex/sessions/2023/11/13/rollout-old.jsonl")
        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: readable)
        let hiddenDir = home.appendingPathComponent(".codex/sessions/2023/11/14", isDirectory: true)
        let hidden = hiddenDir.appendingPathComponent("rollout-newer.jsonl")
        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: hidden)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: hiddenDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                        ofItemAtPath: hiddenDir.path) }

        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        let result = detect(home: home)
        #expect(result.health(agent: .codex, source: .rollout) == .sourceUnreadable)
        if case .found(let files, incomplete: true) =
            CodexRolloutDiscovery.candidates(in: sessions, now: now) {
            #expect(files.map(\.url.lastPathComponent) == ["rollout-old.jsonl"])
        } else {
            Issue.record("monitor candidates should still tail the accessible rollout")
        }
    }

    @Test("an unreadable rollout directory is not treated as an empty source")
    func unreadableRolloutDirectory() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        let directory = home.appendingPathComponent(".codex/sessions/2023/11/14", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                        ofItemAtPath: directory.path) }

        let result = detect(home: home)
        #expect(result.health(agent: .codex, source: .rollout) == .sourceUnreadable)
    }

    // MARK: - Grok

    /// The event set `hooks/install-grok-hooks.py` writes.
    private func grokHooks(_ events: [String]) -> String {
        let groups = events.map {
            #""\#($0)":[{"hooks":[{"type":"command","command":"/app/vibebuddy-forward.sh grok","timeout":5}]}]"#
        }.joined(separator: ",")
        return "{\"hooks\":{\(groups)}}"
    }

    private var grokInstalledEvents: [String] {
        ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
         "PostToolUseFailure", "Stop", "StopFailure", "StopCancelled",
         "Notification", "SubagentStart", "SubagentStop", "SessionEnd"]
    }

    @Test("grok reports not-installed, then missing events, then healthy")
    func grokHookEvidence() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grokHome = unwrittenDirectory()
        defer { try? FileManager.default.removeItem(at: grokHome) }
        #expect(detect(home: home, grokHome: grokHome)
            .health(agent: .grok, source: .hook) == .notInstalled)

        try FileManager.default.createDirectory(at: grokHome, withIntermediateDirectories: true)
        #expect(detect(home: home, grokHome: grokHome)
            .health(agent: .grok, source: .hook) == .eventsMissing)

        try write(grokHooks(grokInstalledEvents),
                  to: grokHome.appendingPathComponent("hooks/vibebuddy.json"))
        let signal = ObservationRuntimeSignal(agent: .grok, source: .hook, lastObservedAt: now)
        let result = detect(home: home, grokHome: grokHome, signals: [signal])
        #expect(result.health(agent: .grok, source: .hook) == .healthy)
        #expect(result.diagnostic(agent: .grok, source: .hook)?.configuredCoverage
            == ObservationEventCoverage.allCases)
    }

    @Test("grok without Notification loses attention coverage even with fresh events")
    func grokAttentionCoverageRequired() throws {
        let grokHome = unwrittenDirectory()
        defer { try? FileManager.default.removeItem(at: grokHome) }
        try write(grokHooks(grokInstalledEvents.filter { $0 != "Notification" }),
                  to: grokHome.appendingPathComponent("hooks/vibebuddy.json"))
        let signal = ObservationRuntimeSignal(agent: .grok, source: .hook, lastObservedAt: now)
        let result = detect(home: nil, grokHome: grokHome, signals: [signal])
        #expect(result.health(agent: .grok, source: .hook) == .eventsMissing)
        #expect(result.diagnostic(agent: .grok, source: .hook)?
            .configuredCoverage.contains(.attention) == false)
    }

    @Test("grok's session transcripts are a declared passive source")
    func grokPassiveSource() throws {
        let grokHome = unwrittenDirectory()
        defer { try? FileManager.default.removeItem(at: grokHome) }
        #expect(detect(home: nil, grokHome: grokHome)
            .health(agent: .grok, source: .transcript) == .notInstalled)

        try FileManager.default.createDirectory(
            at: grokHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let signal = ObservationRuntimeSignal(agent: .grok, source: .transcript, lastObservedAt: now)
        #expect(detect(home: nil, grokHome: grokHome, signals: [signal])
            .health(agent: .grok, source: .transcript) == .healthy)
    }

    @Test("grok diagnostics follow the resolved grok home, not the user's ~/.grok")
    func grokHomeRedirects() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let grokHome = unwrittenDirectory()
        defer { try? FileManager.default.removeItem(at: grokHome) }

        // A complete install sitting at `~/.grok` is the wrong profile when
        // `$GROK_HOME` points elsewhere, and must not be reported as evidence.
        try write(grokHooks(grokInstalledEvents),
                  to: home.appendingPathComponent(".grok/hooks/vibebuddy.json"))
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok/sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let ignored = detect(home: home, grokHome: grokHome)
        #expect(ignored.health(agent: .grok, source: .hook) == .notInstalled)
        #expect(ignored.health(agent: .grok, source: .transcript) == .notInstalled)

        // The same files under the redirected home are what gets inspected.
        try write(grokHooks(grokInstalledEvents),
                  to: grokHome.appendingPathComponent("hooks/vibebuddy.json"))
        let signal = ObservationRuntimeSignal(agent: .grok, source: .hook, lastObservedAt: now)
        let found = detect(home: home, grokHome: grokHome, signals: [signal])
        #expect(found.health(agent: .grok, source: .hook) == .healthy)
        #expect(found.diagnostic(agent: .grok, source: .hook)?.configuredCoverage
            == ObservationEventCoverage.allCases)
    }
}

private extension Array where Element == AgentObservationDiagnostic {
    func diagnostic(agent: AgentKind, source: ObservationSource) -> ObservationSourceDiagnostic? {
        first(where: { $0.agent == agent })?.sources.first(where: { $0.source == source })
    }

    func health(agent: AgentKind, source: ObservationSource) -> ObservationHealth? {
        diagnostic(agent: agent, source: source)?.health
    }
}
