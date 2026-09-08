import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Mac menu clear request")
struct MenuClearRequestTests {
    @Test func sourceAndRoundChangesRejectRenderedTargetsEvenWhenSessionsAreEqual() {
        let idle = AgentSession(id: "same", agent: .codex, project: "A", status: .done,
                                statusSince: Date(timeIntervalSince1970: 100), updatedAt: Date())
        var prefs = MenuSessionPreferences()
        let request = MenuClearRequest([idle], preferences: prefs, sourceID: "mac-1",
                                       roundIDs: [idle.id: "round-1"])
        #expect(request.count == 1)
        #expect(request.isAvailable)
        request.apply(to: &prefs, currentSessions: [idle], currentSourceID: "mac-2",
                      currentRoundIDs: [idle.id: "round-1"])
        #expect(prefs.visible([idle], sourceID: "mac-2", roundIDs: [idle.id: "round-1"]) == [idle])
        #expect(prefs.visible([idle], sourceID: "mac-1", roundIDs: [idle.id: "round-1"]) == [idle])
        request.apply(to: &prefs, currentSessions: [idle], currentSourceID: "mac-1",
                      currentRoundIDs: [idle.id: "round-2"])
        #expect(prefs.visible([idle], sourceID: "mac-1", roundIDs: [idle.id: "round-2"]) == [idle])
        for status in [SessionStatus.working, .needsResponse] {
            var current = idle
            current.status = status
            request.apply(to: &prefs, currentSessions: [current], currentSourceID: "mac-1",
                          currentRoundIDs: [idle.id: "round-1"])
            #expect(prefs.visible([current], sourceID: "mac-1", roundIDs: [idle.id: "round-1"]) == [current])
            #expect(prefs.visible([idle], sourceID: "mac-1", roundIDs: [idle.id: "round-1"]) == [idle])
        }
        request.apply(to: &prefs, currentSessions: [idle], currentSourceID: "mac-1",
                      currentRoundIDs: [idle.id: "round-1"])
        #expect(prefs.visible([idle], sourceID: "mac-1", roundIDs: [idle.id: "round-1"]).isEmpty)
        #expect(!MenuClearRequest([idle], preferences: .init(), sourceID: nil).isAvailable)
    }

    @Test func countsAndEmptyReasonsKeepTheFullSnapshotScope() {
        let done = AgentSession(id: "done", agent: .codex, project: "A", status: .done,
                                hasUnreadCompletion: true, statusSince: Date(), updatedAt: Date())
        let waiting = AgentSession(id: "waiting", agent: .claudeCode, project: "B", status: .needsResponse,
                                   statusSince: Date(), updatedAt: Date())
        var prefs = MenuSessionPreferences()
        prefs.selectedAgents = [.codex]
        let list = MenuProjectList([waiting, done], preferences: prefs, sourceID: "mac")
        #expect(list.visibleCount == 1)
        #expect(list.summary.total == 2)
        #expect(list.summary.requiresInput == 1)
        #expect(list.projects.map(\.title) == ["A"])
        let request = MenuClearRequest([waiting, done], preferences: prefs, sourceID: "mac")
        request.apply(to: &prefs, currentSessions: [waiting, done], currentSourceID: "mac")
        let cleared = MenuProjectList([waiting, done], preferences: prefs, sourceID: "mac")
        #expect(cleared.emptyState == .cleared)
        #expect(cleared.visibleCount == 0)
        #expect(cleared.summary.total == 2)
        prefs.selectedAgents = []
        #expect(MenuProjectList([waiting, done], preferences: prefs, sourceID: "mac").emptyState == .noMatches)
        #expect(MenuProjectList([], preferences: prefs, sourceID: "mac").emptyState == .noSessions)
        prefs.selectedAgents = Set(AgentKind.allCases)
        #expect(MenuProjectList([waiting, done], preferences: prefs, sourceID: "mac").projects.map(\.title) == ["B"])
    }
}
