import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Codex runs a hook only while its recorded trust still covers the hook's
/// current definition, and says nothing when it skips one. These cover the two
/// halves of noticing that: reading `hooks/list`, and turning it into the
/// Settings verdict.
@Suite("Codex hook trust")
struct CodexHookTrustTests {
    private func hook(_ event: String, command: String, trust: String,
                      key: String, enabled: Bool = true) -> [String: Any] {
        ["eventName": event, "command": command, "trustStatus": trust,
         "key": key, "enabled": enabled, "handlerType": "command"]
    }

    private func monitor(_ results: [String: [String: Any]]) throws
        -> (CodexAppServerMonitor, FakeConnection, URL) {
        let socket = FileManager.default.temporaryDirectory
            .appendingPathComponent("vb-sock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let connection = FakeConnection(results: fakeDaemonResults().merging(results) { _, new in new })
        return (CodexAppServerMonitor(socketPath: socket.path, makeClient: { _ in connection }),
                connection, socket)
    }

    @Test("hooks/list counts only our hooks, once each, and flags the ones Codex skips")
    func readsTrust() async throws {
        let forwarder = "\"/opt/vibebuddy/hooks/vibebuddy-forward.sh\" codex"
        let (monitor, _, socket) = try monitor([
            "hooks/list": ["data": [
                // The same definitions are reported once per working directory.
                ["cwd": "/a", "hooks": [
                    hook("preToolUse", command: forwarder, trust: "modified", key: "k1"),
                    hook("stop", command: forwarder, trust: "trusted", key: "k2"),
                    hook("permissionRequest", command: "\"/opt/vibebuddy/hooks/approval-hook.sh\" codex",
                         trust: "untrusted", key: "k3"),
                    // Someone else's hook: not our business, not our count.
                    hook("stop", command: "bash /Users/me/other-agent.sh", trust: "modified", key: "k4"),
                ]],
                ["cwd": "/b", "hooks": [
                    hook("preToolUse", command: forwarder, trust: "modified", key: "k1"),
                ]],
            ]],
        ])
        defer { try? FileManager.default.removeItem(at: socket) }
        let store = SessionStore()
        let run = Task { await monitor.run(store: store) }
        defer { run.cancel() }

        #expect(await waitFor { await monitor.diagnostics().hookTrust != nil })
        let trust = try #require(await monitor.diagnostics().hookTrust)
        #expect(trust.installed == 3)
        #expect(trust.blocked == 2)
        #expect(trust.blockedEvents == ["permissionRequest", "preToolUse"])
    }

    @Test("a hook Codex disabled counts as blocked even while it is trusted")
    func disabledCountsAsBlocked() async throws {
        let forwarder = "\"/opt/vibebuddy/hooks/vibebuddy-forward.sh\" codex"
        let (monitor, _, socket) = try monitor([
            "hooks/list": ["data": [["cwd": "/a", "hooks": [
                hook("stop", command: forwarder, trust: "trusted", key: "k1", enabled: false),
                hook("preToolUse", command: forwarder, trust: "managed", key: "k2"),
            ]]]],
        ])
        defer { try? FileManager.default.removeItem(at: socket) }
        let store = SessionStore()
        let run = Task { await monitor.run(store: store) }
        defer { run.cancel() }

        #expect(await waitFor { await monitor.diagnostics().hookTrust != nil })
        let trust = try #require(await monitor.diagnostics().hookTrust)
        #expect(trust.installed == 2)
        #expect(trust.blockedEvents == ["stop"])
    }

    @Test("a daemon that answers nothing about hooks leaves the verdict unknown")
    func unknownWithoutAnswer() async throws {
        let (monitor, _, socket) = try monitor([:])   // no hooks/list result at all
        defer { try? FileManager.default.removeItem(at: socket) }
        let store = SessionStore()
        let run = Task { await monitor.run(store: store) }
        defer { run.cancel() }

        #expect(await waitFor { await monitor.diagnostics().connected })
        #expect(await monitor.diagnostics().hookTrust == nil)
        #expect(await monitor.diagnostics().lastError == nil)
    }

    @Test("a later failed trust query clears the previous verdict")
    func failedRefreshClearsTrust() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-trust-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        let connection = FakeConnection(results: fakeDaemonResults().merging([
            "hooks/list": ["data": [["hooks": [hook("stop", command: "/opt/vibebuddy-forward.sh codex", trust: "modified", key: "k")]]]]
        ]) { _, new in new })
        let monitor = CodexAppServerMonitor(socketPath: socket.path, usageRefreshInterval: .milliseconds(30),
                                           makeClient: { _ in connection })
        let run = Task { await monitor.run(store: SessionStore()) }
        defer { run.cancel() }
        #expect(await waitFor { await monitor.diagnostics().hookTrust?.blocked == 1 })
        connection.fail("hooks/list")
        #expect(await waitFor { await monitor.diagnostics().hookTrust == nil })
    }

    @Test("blocked hooks become the Settings issue; trusted ones and an unknown verdict do not")
    func issueFromTrust() {
        let home = URL(fileURLWithPath: "/nonexistent/vb-codex-home")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func issue(_ trust: CodexHookTrust?) -> CodexHookConfigurationIssue? {
            ObservationHealthDetector.codexHookConfigurationIssue(
                home: home, hook: nil, now: now, hookTrust: trust)
        }
        let blocked = CodexHookTrust(installed: 12, blockedEvents: ["stop"], blocked: 3)
        #expect(issue(blocked) == .hooksNotTrusted(blocked))
        #expect(issue(CodexHookTrust(installed: 12, blockedEvents: [], blocked: 0)) == nil)
        #expect(issue(nil) == nil)
        let explanation = CodexHookConfigurationIssue.hooksNotTrusted(blocked).explanation
        #expect(explanation.contains("3 of 12"))
        #expect(explanation.contains("stop"))
        #expect(explanation.contains("/hooks"))
    }

    @Test("a fresh healthy hook signal does not excuse hooks the daemon says it skips")
    func freshSignalDoesNotHideBlockedHooks() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let healthy = ObservationSourceDiagnostic(
            source: .hook, health: .healthy, lastObservedAt: now)
        let blocked = CodexHookTrust(installed: 12, blockedEvents: ["stop"], blocked: 1)
        #expect(ObservationHealthDetector.codexHookConfigurationIssue(
            home: URL(fileURLWithPath: "/nonexistent/vb-codex-home"),
            hook: healthy, now: now, hookTrust: blocked) == .hooksNotTrusted(blocked))
    }
}
