import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Grok Bot connection diagnostics")
struct GrokBotDiagnosticTests {
    @Test func connectionFailureAppearsWithoutCreatingOrCompletingSessions() async throws {
        let now = Date()
        let store = SessionStore()
        await store.recordSourceSignal(agent: .grokBot, source: .gateway, health: .sourceUnreadable, at: now)
        let failed = await store.snapshot(now: now)
        #expect(failed.sessions.isEmpty)
        let row = try #require(failed.observationDiagnostics?.first { $0.agent == .grokBot })
        #expect(row.sources.first?.source == .gateway)
        #expect(row.sources.first?.health == .sourceUnreadable)
        await store.recordSourceSignal(agent: .grokBot, source: .gateway, health: .healthy, at: now.addingTimeInterval(1))
        let recovered = await store.snapshot(now: now.addingTimeInterval(1))
        #expect(recovered.sessions.isEmpty)
        #expect(recovered.observationDiagnostics?.first { $0.agent == .grokBot }?.sources.first?.health == .healthy)
    }
}
