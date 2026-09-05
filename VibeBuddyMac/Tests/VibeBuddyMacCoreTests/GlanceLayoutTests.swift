import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("GlanceLayout — notch geometry from NSScreen metrics")
struct GlanceLayoutTests {
    @Test("14-inch MacBook Pro: the housing is what the auxiliary areas leave uncovered")
    func fourteenInch() {
        let notch = NotchGeometry.from(screenWidth: 1512, topInset: 32,
                                       auxiliaryLeftWidth: 663.5, auxiliaryRightWidth: 663.5)
        #expect(notch == NotchGeometry(width: 185, height: 32))
    }

    @Test("no auxiliary areas → no notch, even with a menu-bar-sized inset")
    func notchless() {
        #expect(NotchGeometry.from(screenWidth: 2240, topInset: 0,
                                   auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil) == nil)
        #expect(NotchGeometry.from(screenWidth: 2240, topInset: 24,
                                   auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil) == nil)
    }
}

@Suite("GlanceCardQueue — one card at a time, withdrawn when its wait is over")
struct GlanceCardQueueTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func session(_ id: String, _ status: SessionStatus, wait: WaitKind? = nil,
                         approval: String? = nil) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status, waitKind: wait,
                     pendingApproval: approval.map { PendingApproval(id: $0, tool: "Bash", commandPreview: "ls") },
                     statusSince: t0, updatedAt: t0)
    }

    @Test("an approval card shows for the actionable duration, then expires")
    func actionableExpires() {
        var q = GlanceCardQueue()
        let s = session("a", .needsResponse, wait: .permission, approval: "ap1")
        q.enqueue(SoundAlert(session: s, sound: .needsApproval), now: t0)
        #expect(q.current?.isActionable == true)
        q.tick(now: t0.addingTimeInterval(7.9), sessions: [s], held: false)
        #expect(q.current != nil)
        q.tick(now: t0.addingTimeInterval(8), sessions: [s], held: false)
        #expect(q.current == nil)
    }

    @Test("a completion is passive and short")
    func passiveIsShort() {
        var q = GlanceCardQueue()
        let s = session("a", .done)
        q.enqueue(SoundAlert(session: s, sound: .agentDone), now: t0)
        q.tick(now: t0.addingTimeInterval(2.4), sessions: [], held: false)   // history: stays even if the session is gone
        #expect(q.current != nil)
        q.tick(now: t0.addingTimeInterval(2.5), sessions: [], held: false)
        #expect(q.current == nil)
    }

    @Test("the approval card is withdrawn as soon as that approval is resolved, and the next card advances")
    func withdrawnWhenResolved() {
        var q = GlanceCardQueue()
        let a = session("a", .needsResponse, wait: .permission, approval: "ap1")
        let b = session("b", .done)
        q.enqueue(SoundAlert(session: a, sound: .needsApproval), now: t0)
        q.enqueue(SoundAlert(session: b, sound: .agentDone), now: t0)
        #expect(q.current?.session.id == "a")
        // Approved from the phone: the session is working again.
        q.tick(now: t0.addingTimeInterval(1), sessions: [session("a", .working), b], held: false)
        #expect(q.current?.session.id == "b")
    }

    @Test("holding (hover / expanded) pauses the clock and leaves a grace period after release")
    func holdPauses() {
        var q = GlanceCardQueue()
        let s = session("a", .needsResponse, wait: .permission, approval: "ap1")
        q.enqueue(SoundAlert(session: s, sound: .needsApproval), now: t0)
        q.tick(now: t0.addingTimeInterval(20), sessions: [s], held: true)
        #expect(q.current != nil)
        q.tick(now: t0.addingTimeInterval(21), sessions: [s], held: false)
        #expect(q.current != nil)   // inside the 1.5s grace
        q.tick(now: t0.addingTimeInterval(21.6), sessions: [s], held: false)
        #expect(q.current == nil)
    }

    @Test("the same cue is not repeated; a newer cue for a queued session replaces the stale one")
    func dedupeAndReplace() {
        var q = GlanceCardQueue()
        let a = session("a", .needsResponse, wait: .permission, approval: "ap1")
        let b = session("b", .needsResponse, wait: .question)
        q.enqueue(SoundAlert(session: a, sound: .needsApproval), now: t0)
        q.enqueue(SoundAlert(session: a, sound: .needsApproval), now: t0)
        q.enqueue(SoundAlert(session: b, sound: .needsAnswer), now: t0)
        q.enqueue(SoundAlert(session: b, sound: .longWaitNudge), now: t0)
        q.dismissCurrent(now: t0)
        #expect(q.current?.alert.sound == .longWaitNudge)
        q.dismissCurrent(now: t0)
        #expect(q.current == nil)
    }
}
