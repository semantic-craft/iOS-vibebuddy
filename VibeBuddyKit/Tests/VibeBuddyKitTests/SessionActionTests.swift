import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Session action semantics")
struct SessionActionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        agent: AgentKind = .codex,
        status: SessionStatus,
        question: PendingQuestion? = nil,
        approval: PendingApproval? = nil,
        project: String = "ios-vibebuddy",
        appServer: ObservationHealth? = .healthy
    ) -> AgentSession {
        AgentSession(
            id: "s", agent: agent, project: project,
            status: status,
            waitKind: question != nil ? .question : approval != nil ? .permission : nil,
            pendingApproval: approval,
            pendingQuestion: question,
            observations: appServer.map { [ObservationEvidence(source: .appserver, lastObservedAt: now, health: $0)] },
            statusSince: now, updatedAt: now)
    }

    @Test("an answerable question is Answer, not an instruction")
    func questionIsAnswer() {
        let q = PendingQuestion(id: "q1", prompt: "Which one?")
        let support = SessionActionSupport.resolve(for: session(status: .needsResponse, question: q))
        #expect(support.intent == .answer)
        #expect(support.isAvailable)
    }

    @Test("a read-only question stays Answer and names the Mac prompt")
    func readOnlyQuestionDoesNotBecomeSteer() {
        let q = PendingQuestion(id: "q1", prompt: "Which one?", answerable: false)
        let support = SessionActionSupport.resolve(for: session(status: .needsResponse, question: q))
        #expect(support.intent == .answer)
        #expect(support.unsupportedReason != nil)
        #expect(support.unsupportedReason?.contains("Mac") == true)
    }

    @Test("a running Codex session is a steer; a done one is continue")
    func codexByStatus() {
        #expect(SessionActionSupport.resolve(for: session(status: .working)).intent == .steer)
        #expect(SessionActionSupport.resolve(for: session(status: .done)).intent == .continue)
        #expect(SessionActionSupport.resolve(for: session(status: .working)).isAvailable)
        #expect(SessionActionSupport.resolve(for: session(status: .done)).isAvailable)
    }

    @Test("Claude cannot take steer or continue from the phone")
    func claudeInstructionIsUnsupported() {
        let working = SessionActionSupport.resolve(for: session(agent: .claudeCode, status: .working))
        #expect(working.intent == .steer)
        #expect(working.unsupportedReason?.contains("Claude") == true)
        let done = SessionActionSupport.resolve(for: session(agent: .claudeCode, status: .done))
        #expect(done.intent == .continue)
        #expect(done.unsupportedReason != nil)
    }

    @Test("only a running Codex turn can be stopped from the wrist")
    func stopAvailability() {
        #expect(SessionActionSupport.resolveStop(for: session(status: .working)).isAvailable)
        #expect(SessionActionSupport.resolveStop(for: session(status: .working)).intent == .stop)
        for status in [SessionStatus.done, .needsResponse] {
            let support = SessionActionSupport.resolveStop(for: session(status: status))
            #expect(support.intent == .stop)
            #expect(support.unsupportedReason != nil)
        }
        // Claude Code is unsupported at every status, and says where to go.
        for status in SessionStatus.allCases {
            let support = SessionActionSupport.resolveStop(for: session(agent: .claudeCode, status: status))
            #expect(support.unsupportedReason == "Stop this on your Mac.")
        }
        #expect(SessionActionSupport.resolveStop(for: session(agent: .grokBot, status: .working))
            .unsupportedReason?.contains("Grok Bot") == true)
        #expect(SessionActionSupport.resolveStop(for: session(agent: .cursor, status: .working))
            .unsupportedReason?.contains("Cursor") == true)
        #expect(SessionActionSupport.resolveStop(for: session(agent: .grok, status: .working))
            .isAvailable == false)
        // A Codex session the app-server connection is not carrying (rollout or
        // hooks only, or the connection is unhealthy) cannot be stopped at all.
        #expect(SessionActionSupport.resolveStop(for: session(status: .working, appServer: nil))
            .isAvailable == false)
        #expect(SessionActionSupport.resolveStop(for: session(status: .working, appServer: .temporarilySilent))
            .unsupportedReason == "Your Mac isn't connected to Codex right now.")
    }

    @Test("the send caption names Mac, project and agent")
    func targetCaption() {
        let s = session(status: .working, project: "search-indexer")
        #expect(SessionActionSupport.targetCaption(macName: "Studio", session: s)
                == "Studio · search-indexer · Codex")
        #expect(SessionActionSupport.targetCaption(macName: "  ", session: s)
                .hasPrefix("Mac ·"))
    }

}
