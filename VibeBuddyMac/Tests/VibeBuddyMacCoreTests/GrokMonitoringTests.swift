import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Grok monitoring onboarding")
struct GrokMonitoringTests {
    @Test("enabling configures hooks; disabling survives restart and retains foreign hooks")
    func installAndDisable() throws {
        let home = try HookInstallerTests.Home()
        defer { home.remove() }
        try home.mkdir(".grok")
        try home.write(".grok/hooks/other.json", "{\"hooks\":{}}")
        #expect(!home.installer.grokMonitoringConfiguration.enabled)
        #expect(home.installer.setGrokMonitoring(true).failures == 0)
        #expect(home.installer.grokMonitoringConfiguration.enabled)
        #expect(home.installer.grokMonitoringConfiguration.configured)
        #expect(home.installer.setGrokMonitoring(false).failures == 0)
        #expect(!home.installer.grokMonitoringConfiguration.enabled)
        #expect(home.exists(".grok/hooks/other.json"))
        _ = home.installer.refreshOnLaunch()
        #expect(!home.exists(".grok/hooks/vibebuddy.json"))
        // The old CLI install path remains an explicit opt-in too.
        #expect(home.installer.install([.grok]).failures == 0)
        #expect(home.installer.grokMonitoringConfiguration.enabled)
        #expect(home.installer.install([.grok], approval: true).failures == 0)
        try FileManager.default.removeItem(at: home.installer.paths.script("approval-hook.sh"))
        #expect(!home.installer.grokMonitoringConfiguration.configured)
        #expect(home.installer.setGrokMonitoring(true).failures == 0)
        #expect(home.installer.grokMonitoringConfiguration.configured)
    }

    @Test("failed setup retains intent and a retryable error, never claims configured")
    func failedInstall() throws {
        var home = try HookInstallerTests.Home()
        defer { home.remove() }
        try home.mkdir(".grok")
        home.source = home.url("missing-scripts")
        #expect(home.installer.setGrokMonitoring(true).failures > 0)
        #expect(home.installer.grokMonitoringConfiguration.enabled)
        #expect(!home.installer.grokMonitoringConfiguration.configured)
        #expect(home.installer.grokMonitoringConfiguration.error != nil)
        home.source = HookInstallerTests.repo.appendingPathComponent("hooks")
        #expect(home.installer.setGrokMonitoring(true).failures == 0)
        #expect(home.installer.grokMonitoringConfiguration.error == nil)
    }

    @Test("an already running session is discovered without inventing progress, then becomes one live session")
    func discoveryToLiveAndDisable() async throws {
        let home = try HookInstallerTests.Home()
        defer { home.remove() }
        try home.mkdir(".grok")
        let installer = home.installer
        let now = Date()
        let registry = """
        [{"session_id":"grok-existing","pid":\(ProcessInfo.processInfo.processIdentifier),"cwd":"/tmp/existing-project"}]
        """
        try home.write(".grok/active_sessions.json", registry)
        let store = SessionStore(grokHome: installer.paths.grokDirectory,
            grokMonitoringConfiguration: { installer.grokMonitoringConfiguration })
        #expect(await store.snapshot(now: now).grokMonitoring?.discoveredSessions.isEmpty == true)
        #expect(installer.setGrokMonitoring(true).failures == 0)
        await store.sweep(now: now)
        let found = await store.snapshot(now: now)
        #expect(found.sessions.isEmpty)
        #expect(found.grokMonitoring?.discoveredSessions.map(\.id) == ["grok-existing"])
        #expect(found.grokMonitoring?.connectedSessionCount == 0)
        let wire = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(found))
        #expect(wire.grokMonitoring == found.grokMonitoring)
        let event = Data(#"{"hookEventName":"user_prompt_submit","sessionId":"grok-existing","cwd":"/tmp/existing-project"}"#.utf8)
        #expect(await store.ingest(event, agent: .grok, receivedAt: now))
        let live = await store.snapshot(now: now)
        #expect(live.sessions.count == 1)
        #expect(live.sessions.first?.status == .working)
        #expect(live.grokMonitoring?.discoveredSessions.isEmpty == true)
        #expect(live.grokMonitoring?.connectedSessionCount == 1)
        #expect(installer.setGrokMonitoring(false).failures == 0)
        await store.sweep(now: now.addingTimeInterval(1))
        #expect(await store.snapshot(now: now).sessions.isEmpty)
        #expect(await store.ingest(event, agent: .grok, receivedAt: now) == false)
        #expect(await store.snapshot(now: now).grokMonitoring?.discoveredSessions.isEmpty == true)
        #expect(installer.setGrokMonitoring(true).failures == 0)
        await store.sweep(now: now.addingTimeInterval(2))
        #expect(await store.snapshot(now: now).grokMonitoring?.discoveredSessions.count == 1)
        try home.write(".grok/active_sessions.json", "[]")
        await store.sweep(now: now.addingTimeInterval(3))
        #expect(await store.snapshot(now: now).grokMonitoring?.discoveredSessions.isEmpty == true)
    }
}
