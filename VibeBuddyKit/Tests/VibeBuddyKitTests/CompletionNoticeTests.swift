import Foundation
import Testing
@testable import VibeBuddyKit

struct CompletionNoticeTests {
    @Test func queuedNoticeMustStillHaveAConfirmedDecision() {
        var queued = CompletionNotice(id: "source/session/round", deadline: Date(), state: .summary, text: "Finished drawing")
        queued.presentationRevision = "one"
        var current = queued
        #expect(current.permitsDelivery(of: queued))
        current.state = .cancelled
        #expect(!current.permitsDelivery(of: queued))
        current.state = .pending
        #expect(!current.permitsDelivery(of: queued))
        current.state = .plain
        #expect(current.permitsDelivery(of: queued))
        current.presentationRevision = "two"
        #expect(!current.permitsDelivery(of: queued))
        current = queued
        current.id = "source/session/next-round"
        #expect(!current.permitsDelivery(of: queued))
    }

    private func input(_ session: AgentSession, _ now: Date) -> SoundPolicyInput {
        .init(sessions: [session], now: now, appActive: false, quietMode: false)
    }
    @Test func pendingDoesNotSwallowPermissionAndUsesOneDecision() throws {
        let t = Date()
        var s = AgentSession(id: "notice", agent: .codex, project: "synthetic", status: .working,
                             attention: .followed, statusSince: t.addingTimeInterval(-60), updatedAt: t)
        let policy = SoundPolicy()
        #expect(policy.evaluate(input(s, t)).isEmpty)
        s.status = .done; s.hasUnreadCompletion = true; s.completionID = "one"; s.statusSince = t
        s.completionNotice = .init(id: "source/session/one", deadline: t.addingTimeInterval(12))
        #expect(policy.evaluate(input(s, t)).isEmpty)
        // A phone cannot invent plain wording while the Mac's committed decision is in transit.
        #expect(policy.evaluate(input(s, t.addingTimeInterval(13))).isEmpty)
        s.completionNotice?.state = .summary; s.completionNotice?.text = "Fixed; device validation pending."
        let alerts = policy.evaluate(input(s, t.addingTimeInterval(14)))
        #expect(alerts.count == 1)
        #expect(alerts.first?.session.summary == "Fixed; device validation pending.")
        #expect(policy.evaluate(input(s, t.addingTimeInterval(15))).isEmpty)
        s.status = .working; s.completionNotice = nil; s.statusSince = t
        _ = policy.evaluate(input(s, t))
        s.status = .done; s.statusSince = t.addingTimeInterval(60); s.completionID = "two"
        s.completionNotice = .init(id: "source/session/two", deadline: t.addingTimeInterval(72))
        #expect(policy.evaluate(input(s, t.addingTimeInterval(60))).isEmpty)
        s.status = .needsResponse; s.waitKind = .permission; s.completionNotice = nil
        #expect(policy.evaluate(input(s, t.addingTimeInterval(61))).first?.sound == .needsApproval)
    }
}
