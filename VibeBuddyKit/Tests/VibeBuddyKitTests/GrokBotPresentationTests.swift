import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Grok Bot read-only presentation")
struct GrokBotPresentationTests {
    @Test("Wait notifications have no remote actions, including incomplete question metadata")
    func noRemoteNotificationActions() {
        let now = Date()
        var waiting = AgentSession(id: "grokBot:test:bot", agent: .grokBot, project: "Bot", status: .needsResponse,
            waitKind: .question, statusSince: now, updatedAt: now)
        #expect(SoundAlert(session: waiting, sound: .needsAnswer).actionCategory == nil)
        #expect(!SessionActionSupport.resolve(for: waiting).isAvailable)
        waiting.pendingQuestion = PendingQuestion(id: "question", prompt: "Reply", answerable: true)
        #expect(SoundAlert(session: waiting, sound: .needsAnswer).actionCategory == nil)
        #expect(!SessionActionSupport.resolve(for: waiting).isAvailable)
        waiting.waitKind = .permission
        waiting.pendingApproval = PendingApproval(id: "approval", tool: "Bash", commandPreview: "echo test", command: "echo test", answerable: true)
        #expect(SoundAlert(session: waiting, sound: .needsApproval).actionCategory == nil)
        #expect(WatchApprovalEligibility.approvalId(for: waiting) == nil)
    }

    @Test("Finished and running Grok Bot tasks do not advertise unsupported instructions")
    func noRemoteContinuation() {
        let now = Date()
        for status in [SessionStatus.done, .working] {
            let session = AgentSession(id: "grokBot:test:bot", agent: .grokBot, project: "Bot", status: status,
                statusSince: now, updatedAt: now)
            #expect(!SessionActionSupport.resolve(for: session).isAvailable)
            #expect(session.canJump)
        }
    }
}
