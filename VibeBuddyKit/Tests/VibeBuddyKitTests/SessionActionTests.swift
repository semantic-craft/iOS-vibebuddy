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
        project: String = "ios-vibebuddy"
    ) -> AgentSession {
        AgentSession(
            id: "s", agent: agent, project: project,
            status: status,
            waitKind: question != nil ? .question : approval != nil ? .permission : nil,
            pendingApproval: approval,
            pendingQuestion: question,
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

    @Test("the send caption names Mac, project and agent")
    func targetCaption() {
        let s = session(status: .working, project: "search-indexer")
        #expect(SessionActionSupport.targetCaption(macName: "Studio", session: s)
                == "Studio · search-indexer · Codex")
        #expect(SessionActionSupport.targetCaption(macName: "  ", session: s)
                .hasPrefix("Mac ·"))
    }

    @Test("HTTP 200 accepted is not a transport miss; 202 and 409 are failures")
    func httpMapping() {
        #expect(SessionActionOutcome.fromHTTP(statusCode: 200, body: ["status": "accepted"]) == .accepted)
        #expect(SessionActionOutcome.fromHTTP(statusCode: 202, body: ["status": "failed", "error": "gone"])
                == .failed("gone"))
        #expect(SessionActionOutcome.fromHTTP(statusCode: 409, body: ["status": "failed", "error": "expired"])
                == .failed("expired"))
        #expect(SessionActionOutcome.fromHTTP(statusCode: 503, body: ["error": "down"]) == .failed("down"))
    }
}
