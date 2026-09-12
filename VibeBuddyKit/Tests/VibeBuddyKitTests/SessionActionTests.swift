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

    // MARK: - Control channels

    private func cursor(_ status: SessionStatus, channel: ControlChannel?, id: String = "c1",
                        sources: [ObservationSource] = []) -> AgentSession {
        AgentSession(
            id: id, agent: .cursor, project: "ios-vibebuddy", status: status,
            observations: sources.map { ObservationEvidence(source: $0, lastObservedAt: now, health: .healthy) },
            controlChannel: channel,
            statusSince: now, updatedAt: now)
    }

    @Test("the Mac's channel stamp decides before the agent does")
    func channelMatrix() {
        // hook: supplement queued, continue through the CLI, no interrupt.
        let hookWorking = SessionActionSupport.resolve(for: cursor(.working, channel: .hook))
        #expect(hookWorking.intent == .steer && hookWorking.isAvailable && hookWorking.note != nil)
        #expect(SessionActionSupport.resolve(for: cursor(.done, channel: .hook)).isAvailable)
        #expect(SessionActionSupport.resolveStop(for: cursor(.working, channel: .hook))
            .unsupportedReason == "Stop this in Cursor on your Mac.")
        // acp: everything, with the running turn's supplement still queued.
        let acpWorking = SessionActionSupport.resolve(for: cursor(.working, channel: .acp))
        #expect(acpWorking.isAvailable && acpWorking.note?.contains("next message") == true)
        #expect(SessionActionSupport.resolve(for: cursor(.done, channel: .acp)).isAvailable)
        #expect(SessionActionSupport.resolveStop(for: cursor(.working, channel: .acp)).isAvailable)
        #expect(SessionActionSupport.resolveStop(for: cursor(.done, channel: .acp)).isAvailable == false)
        // cloud: one run at a time — no supplement, a new run when idle, cancel when running.
        #expect(SessionActionSupport.resolve(for: cursor(.working, channel: .cloud, id: "bc-1")).isAvailable == false)
        let cloudDone = SessionActionSupport.resolve(for: cursor(.done, channel: .cloud, id: "bc-1"))
        #expect(cloudDone.isAvailable && cloudDone.note?.contains("new run") == true)
        #expect(SessionActionSupport.resolveStop(for: cursor(.working, channel: .cloud, id: "bc-1")).isAvailable)
        // none: seen, not reachable — and a cloud row without a key says which setup is missing.
        #expect(SessionActionSupport.resolve(for: cursor(.working, channel: ControlChannel.none))
            .unsupportedReason?.contains("hooks") == true)
        #expect(SessionActionSupport.resolve(for: cursor(.done, channel: ControlChannel.none, id: "bc-2"))
            .unsupportedReason?.contains("API key") == true)
        #expect(SessionActionSupport.resolveStop(for: cursor(.working, channel: ControlChannel.none, id: "bc-2"))
            .unsupportedReason?.contains("API key") == true)
    }

    @Test("an older Mac's snapshot infers the channel the way the clients always did")
    func channelInference() {
        #expect(ControlChannel.infer(for: cursor(.working, channel: nil, sources: [.hook, .transcript])) == .hook)
        #expect(ControlChannel.infer(for: cursor(.working, channel: nil, sources: [.transcript])) == ControlChannel.none)
        #expect(ControlChannel.infer(for: cursor(.working, channel: nil, sources: [.cloud])) == .cloud)
        #expect(ControlChannel.infer(for: session(status: .working)) == .appserver)
        #expect(ControlChannel.infer(for: session(status: .working, appServer: nil)) == nil)
        #expect(ControlChannel.infer(for: session(agent: .claudeCode, status: .working)) == nil)
        // The stamp wins over the evidence when both are present.
        #expect(ControlChannel.infer(for: cursor(.working, channel: .acp, sources: [.hook])) == .acp)
        // And the pre-stamp Cursor behaviour is unchanged for an unstamped session.
        #expect(SessionActionSupport.resolve(for: cursor(.working, channel: nil, sources: [.transcript]))
            .unsupportedReason?.contains("hooks") == true)
        #expect(SessionActionSupport.resolve(for: cursor(.working, channel: nil, sources: [.hook])).isAvailable)
    }

    @Test("the channel travels in the snapshot and an old snapshot decodes without it")
    func channelCodable() throws {
        let stamped = cursor(.working, channel: .acp)
        let data = try JSONEncoder().encode(stamped)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(decoded.controlChannel == .acp)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "controlChannel")
        let old = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.controlChannel == nil)
    }

    @Test("the wrist's stop block follows the channel")
    func watchStopBlock() {
        #expect(WatchStopOffer.resolve(for: cursor(.working, channel: .hook))
            == .blocked(.macOnly))
        #expect(WatchStopBlock.macOnly.message(agent: .cursor) == "Stop this in Cursor on your Mac.")
        #expect(WatchStopOffer.resolve(for: cursor(.working, channel: .acp)) == .offered)
        #expect(WatchStopOffer.resolve(for: cursor(.working, channel: .cloud, id: "bc-1")) == .offered)
        #expect(WatchStopOffer.resolve(for: cursor(.working, channel: ControlChannel.none, id: "bc-1"))
            == .blocked(.macNeedsSetup))
    }

}
