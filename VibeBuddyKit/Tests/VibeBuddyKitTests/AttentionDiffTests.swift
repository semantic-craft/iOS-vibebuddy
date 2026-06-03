import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("AttentionDiff")
struct AttentionDiffTests {

    private func session(_ id: String, _ status: SessionStatus) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("flags only sessions that newly entered needsResponse")
    func newly() {
        let old = [session("a", .working), session("b", .needsResponse)]
        let new = [session("a", .needsResponse), session("b", .needsResponse), session("c", .needsResponse)]
        #expect(AttentionDiff.newlyNeedingResponse(old: old, new: new).map(\.id) == ["a", "c"])
    }

    @Test("nothing newly waiting when the waiting set is unchanged")
    func none() {
        let old = [session("a", .needsResponse)]
        let new = [session("a", .needsResponse)]
        #expect(AttentionDiff.newlyNeedingResponse(old: old, new: new).isEmpty)
    }

    @Test("with empty old, every waiting session is new (caller may suppress on first connect)")
    func emptyOld() {
        let new = [session("a", .needsResponse), session("b", .working)]
        #expect(AttentionDiff.newlyNeedingResponse(old: [], new: new).map(\.id) == ["a"])
    }
}
