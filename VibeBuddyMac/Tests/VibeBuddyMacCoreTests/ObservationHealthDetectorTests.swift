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
