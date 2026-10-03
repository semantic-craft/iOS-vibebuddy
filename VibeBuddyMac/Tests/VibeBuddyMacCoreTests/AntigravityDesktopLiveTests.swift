import Foundation
import Testing
@testable import VibeBuddyMacCore

/// Opt-in, read-only acceptance against a synthetic conversation that the user
/// already cancelled in Antigravity. Never creates, resumes or cancels a task.
struct AntigravityDesktopLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_ANTIGRAVITY_CANCELLED_PROBE"] != nil))
    func readsNativeCancelledConversation() async throws {
        let id = try #require(ProcessInfo.processInfo.environment["VIBEBUDDY_ANTIGRAVITY_CANCELLED_PROBE"])
        let client = AntigravityDesktopClient()
        let conversations = try await client.conversations()
        let conversation = try #require(conversations.first { $0.id == id })
        #expect(conversation.status.hasSuffix("IDLE"))
        let steps = try await client.steps(for: conversation)
        #expect(steps.observation(for: conversation).state == .cancelled)
        let monitor = AntigravityDesktopMonitor()
        #expect(await monitor.events(for: steps.observation(for: conversation), now: Date()).isEmpty)
    }
}
