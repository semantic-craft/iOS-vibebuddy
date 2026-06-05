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

    @Test("the prompt tells the model to keep its own instructions private (both styles)")
    func confidentiality() {
        for style in [VoicePrompt.ActionStyle.directive, .tools] {
            let p = VoicePrompt.systemPrompt(sessions: [], actionStyle: style)
            #expect(p.lowercased().contains("never reveal"),
                    "the \(style) prompt should refuse to disclose its own instructions")
        }
    }

    @Test("the tools action-style points at the function tools and drops the ACTION directive")
    func toolsStyle() {
        let p = VoicePrompt.systemPrompt(
            sessions: [session("payments-api", .needsResponse, wait: .permission)],
            actionStyle: .tools)
        #expect(p.contains("payments-api"))       // still lists live sessions
        #expect(p.contains("approve_session"))    // names the tools the model is given
        #expect(!p.contains("ACTION:"))           // no spoken-text directive in voice mode
    }

    @Test("the conversation language pins the reply language")
    func language() {
        let en = VoicePrompt.systemPrompt(sessions: [], language: .english)
        #expect(en.contains("Always reply in English."))
        let zh = VoicePrompt.systemPrompt(sessions: [], language: .chinese)
        #expect(zh.contains("Always reply in Chinese"))
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
