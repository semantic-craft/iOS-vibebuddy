import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Claude, Codex and Grok observation health diagnostics")
struct ObservationHealthDetectorTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-health-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        let absent = ObservationHealthDetector.detect(home: home, signals: [], now: now)
        #expect(absent.health(agent: .claudeCode, source: .hook) == .notInstalled)

        try write(#"{"hooks":{"Stop":[{"hooks":[{"command":"echo user"}]}]}}"#,
                  to: home.appendingPathComponent(".claude/settings.json"))
        let missingEvents = ObservationHealthDetector.detect(home: home, signals: [], now: now)
        #expect(missingEvents.health(agent: .claudeCode, source: .hook) == .eventsMissing)
    }

    @Test("Codex async incompatibility is reported explicitly")
    func codexAsyncIncompatible() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("model = \"gpt\"\n", to: home.appendingPathComponent(".codex/config.toml"))
        try write(#"{"hooks":{"SessionStart":[{"hooks":[{"command":"/app/vibebuddy-forward.sh codex","async":true}]}]}}"#,
                  to: home.appendingPathComponent(".codex/hooks.json"))

        let result = ObservationHealthDetector.detect(home: home, signals: [], now: now)
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

        let result = ObservationHealthDetector.detect(home: home, signals: [], now: now)
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
        let stale = ObservationHealthDetector.detect(home: home, signals: [old], now: now,
                                                     staleAfter: 600)
        #expect(stale.health(agent: .codex, source: .rollout) == .temporarilySilent)

        let fresh = ObservationRuntimeSignal(agent: .codex, source: .rollout,
                                             lastObservedAt: now,
                                             observedCoverage: [.turn, .tool])
        let healthy = ObservationHealthDetector.detect(home: home, signals: [fresh], now: now,
                                                       staleAfter: 600)
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
        let futureResult = ObservationHealthDetector.detect(
            home: futureHome, signals: [], now: now)
        #expect(futureResult.health(agent: .codex, source: .rollout) == .unknownVersion)

        let metadataHome = try tempHome()
        defer { try? FileManager.default.removeItem(at: metadataHome) }
        try write("model = \"gpt\"\n", to: metadataHome.appendingPathComponent(".codex/config.toml"))
        let metadata = metadataHome.appendingPathComponent(".codex/sessions/2023/11/14/rollout-metadata.jsonl")
        try write(#"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"#,
                  to: metadata)
        let metadataResult = ObservationHealthDetector.detect(
            home: metadataHome, signals: [], now: now)
        #expect(metadataResult.health(agent: .codex, source: .rollout) == .eventsMissing)

        try write(
            #"{"type":"session_meta","payload":{"cli_version":"0.151.0-alpha.7.2"}}"# + "\n" +
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            to: metadata)
        let supportedResult = ObservationHealthDetector.detect(
            home: metadataHome, signals: [], now: now)
        #expect(supportedResult.health(agent: .codex, source: .rollout) == .healthy)
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

        let result = ObservationHealthDetector.detect(home: home, signals: [], now: now)
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
        #expect(ObservationHealthDetector.detect(home: home, signals: [], now: now)
            .health(agent: .grok, source: .hook) == .notInstalled)

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok", isDirectory: true),
            withIntermediateDirectories: true)
        #expect(ObservationHealthDetector.detect(home: home, signals: [], now: now)
            .health(agent: .grok, source: .hook) == .eventsMissing)

        try write(grokHooks(grokInstalledEvents),
                  to: home.appendingPathComponent(".grok/hooks/vibebuddy.json"))
        let signal = ObservationRuntimeSignal(agent: .grok, source: .hook, lastObservedAt: now)
        let result = ObservationHealthDetector.detect(home: home, signals: [signal], now: now)
        #expect(result.health(agent: .grok, source: .hook) == .healthy)
        #expect(result.diagnostic(agent: .grok, source: .hook)?.configuredCoverage
            == ObservationEventCoverage.allCases)
    }

    @Test("grok without Notification loses attention coverage even with fresh events")
    func grokAttentionCoverageRequired() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok", isDirectory: true),
            withIntermediateDirectories: true)
        try write(grokHooks(grokInstalledEvents.filter { $0 != "Notification" }),
                  to: home.appendingPathComponent(".grok/hooks/vibebuddy.json"))
        let signal = ObservationRuntimeSignal(agent: .grok, source: .hook, lastObservedAt: now)
        let result = ObservationHealthDetector.detect(home: home, signals: [signal], now: now)
        #expect(result.health(agent: .grok, source: .hook) == .eventsMissing)
        #expect(result.diagnostic(agent: .grok, source: .hook)?
            .configuredCoverage.contains(.attention) == false)
    }

    @Test("grok's session transcripts are a declared passive source")
    func grokPassiveSource() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ObservationHealthDetector.detect(home: home, signals: [], now: now)
            .health(agent: .grok, source: .transcript) == .notInstalled)

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok/sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let signal = ObservationRuntimeSignal(agent: .grok, source: .transcript, lastObservedAt: now)
        #expect(ObservationHealthDetector.detect(home: home, signals: [signal], now: now)
            .health(agent: .grok, source: .transcript) == .healthy)
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
