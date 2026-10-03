import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Antigravity source and read-only waiting")
struct AntigravityPresentationTests {
    @Test func nativePermissionRemainsReadOnlyThroughWatchRelay() throws {
        let now = Date()
        var session = AgentSession(id: "native-permission", agent: .antigravity,
            project: "Acceptance", status: .needsResponse, waitKind: .permission,
            statusSince: now, updatedAt: now)
        session.agentSource = "Desktop"
        session.controlChannel = .some(.none)
        #expect(session.agentSourceLabel == "Antigravity · Desktop")
        #expect(WaitHandling.resolve(for: session) == .macNativePrompt)
        #expect(!SessionActionSupport.resolve(for: session).isAvailable)
        let state = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [session], serverTime: now, sourceID: "acceptance"),
            quotas: [], relay: .live, now: now)
        let decoded = try JSONDecoder().decode(WatchDashboardState.self, from: JSONEncoder().encode(state))
        let alert = try #require(decoded.alerts.first)
        #expect(alert.sourceName == "Antigravity · Desktop")
        #expect(alert.handling == .macNativePrompt)
        #expect(!alert.isDecidable && !alert.isAnswerable)
        session.agentSource = "CLI"
        #expect(WatchFollowedTask(session).sourceName == "Antigravity · CLI")
    }
}
