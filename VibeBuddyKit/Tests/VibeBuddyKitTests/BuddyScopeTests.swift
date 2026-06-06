import Testing
import Foundation
import VibeBuddyKit

@Suite("BuddyScope")
struct BuddyScopeTests {
    private func s(_ id: String) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: .working,
                     statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("a selected subset returns just those sessions, in original order")
    func subset() {
        let all = [s("a"), s("b"), s("c")]
        let r = BuddyScope.included(from: all, selectedIDs: ["c", "a"])
        #expect(r.map(\.id) == ["a", "c"])
    }

    @Test("empty selection means all sessions (none selected = all)")
    func emptyMeansAll() {
        let all = [s("a"), s("b")]
        #expect(BuddyScope.included(from: all, selectedIDs: []).map(\.id) == ["a", "b"])
    }

    @Test("a selection that matches no live session falls back to all")
    func noLiveMatchMeansAll() {
        let all = [s("a"), s("b")]
        #expect(BuddyScope.included(from: all, selectedIDs: ["ghost"]).map(\.id) == ["a", "b"])
    }

    @Test("a partial match returns only the matches, ignoring stale IDs")
    func partialMatch() {
        let all = [s("a"), s("b"), s("c")]
        let r = BuddyScope.included(from: all, selectedIDs: ["b", "gone"])
        #expect(r.map(\.id) == ["b"])
    }

    @Test("pruning keeps only IDs that still have a live session")
    func prune() {
        let live = [s("a"), s("c")]
        #expect(BuddyScope.pruned(["a", "b", "c", "d"], toLive: live) == ["a", "c"])
    }

    @Test("pruning an empty set stays empty")
    func pruneEmpty() {
        #expect(BuddyScope.pruned([], toLive: [s("a")]).isEmpty)
    }
}
