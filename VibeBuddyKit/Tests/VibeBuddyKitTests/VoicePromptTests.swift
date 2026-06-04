import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("VoicePrompt — system prompt & action parsing")
struct VoicePromptTests {

    private func session(_ p: String, _ status: SessionStatus, wait: WaitKind? = nil) -> AgentSession {
        AgentSession(id: p, agent: .claudeCode, project: p, status: status, waitKind: wait,
                     statusSince: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("the system prompt lists sessions with their status")
    func prompt() {
        let p = VoicePrompt.systemPrompt(sessions: [session("payments-api", .needsResponse, wait: .permission)])
        #expect(p.contains("payments-api"))
        #expect(p.contains("waiting for approval"))
        #expect(p.contains("ACTION:"))
    }

    @Test("a plain reply has no action")
    func plain() {
        let (spoken, action) = VoicePrompt.parse("Two sessions are running and one needs you.")
        #expect(action == .none)
        #expect(spoken == "Two sessions are running and one needs you.")
    }

    @Test("an approve directive parses, and the spoken part excludes it")
    func approve() {
        let (spoken, action) = VoicePrompt.parse("Sure, approving payments-api.\nACTION: approve payments-api")
        #expect(action == .approve(project: "payments-api"))
        #expect(spoken == "Sure, approving payments-api.")
    }

    @Test("a deny directive parses")
    func deny() {
        let (_, action) = VoicePrompt.parse("Denying that one.\nACTION: deny docs-site")
        #expect(action == .deny(project: "docs-site"))
    }

    @Test("an answer directive parses project and text")
    func answer() {
        let (_, action) = VoicePrompt.parse("Telling it to use main.\nACTION: answer docs-review :: use the main branch")
        #expect(action == .answer(project: "docs-review", text: "use the main branch"))
    }
}
