import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Menu session visibility")
struct MenuSessionPreferencesTests {
    @Test func clearIsLocalAndSurvivesReadingAndPersistence() throws {
        var session = AgentSession(id: "a", agent: .codex, project: "Example", status: .done, statusSince: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100))
        session.completionID = "turn-1"
        session.hasUnreadCompletion = true
        var prefs = MenuSessionPreferences()
        prefs.clear([session], sourceID: "mac")
        #expect(session.hasUnreadCompletion)
        #expect(prefs.visible([session], sourceID: "mac").isEmpty)
        session.hasUnreadCompletion = false
        session.updatedAt = Date()
        let restored = try JSONDecoder().decode(MenuSessionPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored.visible([session], sourceID: "mac").isEmpty)
        #expect(restored.visible([session], sourceID: "other-mac").count == 1)
        session.completionID = "turn-2"
        #expect(restored.visible([session], sourceID: "mac").count == 1)
    }
    @Test func clearRespectsFilterAndNeverMasksActionableState() {
        var a = AgentSession(id: "a", agent: .codex, project: "A", status: .done,
                             statusSince: Date(timeIntervalSince1970: 100), updatedAt: Date())
        let b = AgentSession(id: "b", agent: .claudeCode, project: "B", status: .done,
                             statusSince: Date(timeIntervalSince1970: 100), updatedAt: Date())
        var prefs = MenuSessionPreferences()
        prefs.selectedAgents = [.codex]
        prefs.clear([a, b], sourceID: "mac")
        prefs.selectedAgents = Set(AgentKind.allCases)
        #expect(prefs.visible([a, b], sourceID: "mac").map(\.id) == ["b"])
        a.status = .working
        #expect(prefs.visible([a], sourceID: "mac").count == 1)
        a.status = .done
        a.failed = true
        #expect(prefs.visible([a], sourceID: "mac").count == 1)
        a.failed = false
        a.statusSince = Date(timeIntervalSince1970: 200)
        #expect(prefs.visible([a], sourceID: "mac").count == 1)
    }
    @Test func staleClearCannotHideNewCompletion() throws {
        let old = AgentSession(id: "a", agent: .codex, project: "A", status: .done,
                               completionID: "first", statusSince: Date(), updatedAt: Date())
        var current = old
        current.completionID = "second"
        var prefs = MenuSessionPreferences()
        prefs.clear([old], currentSessions: [current], sourceID: "mac")
        #expect(prefs.visible([current], sourceID: "mac").count == 1)
        prefs.selectedStates = [.idle]
        prefs.selectedAgents = [.codex]
        prefs.collapsedGroups = ["working", "done"]
        let restored = try JSONDecoder().decode(MenuSessionPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored == prefs)
        #expect(restored.filtered([current]).count == 1)
        current.hasUnreadCompletion = true
        #expect(restored.filtered([current]).isEmpty)
    }
    @Test func idleRoundSurvivesRestartButNotOfflineNewTurn() throws {
        let idle = AgentSession(id: "a", agent: .codex, project: "A", status: .done,
                                statusSince: Date(timeIntervalSince1970: 100), updatedAt: Date())
        var prefs = MenuSessionPreferences()
        prefs.clear([idle], sourceID: "mac", roundIDs: ["a": "round-1"])
        let restored = try JSONDecoder().decode(MenuSessionPreferences.self, from: JSONEncoder().encode(prefs))
        var recovered = idle
        recovered.statusSince = Date(timeIntervalSince1970: 200)
        #expect(restored.visible([recovered], sourceID: "mac", roundIDs: ["a": "round-1"]).isEmpty)
        #expect(restored.visible([recovered], sourceID: "mac", roundIDs: ["a": "round-2"]).count == 1)
        #expect(restored.visible([recovered], sourceID: "mac").count == 1)
        prefs.clear([idle], currentSessions: [recovered], sourceID: "mac",
                    roundIDs: ["a": "round-1"], currentRoundIDs: ["a": "round-2"])
        #expect(prefs.visible([recovered], sourceID: "mac", roundIDs: ["a": "round-2"]).count == 1)
        #expect(!recovered.hasUnreadCompletion)
        #expect(recovered.completionID == nil)
    }

    @Test func filteredCleanupPreservesDashboardAndCompletionReminders() throws {
        let since = Date(timeIntervalSince1970: 0)
        let done = AgentSession(id: "done", agent: .codex, project: "A", status: .done,
                                hasUnreadCompletion: true, completionID: "turn-1", attention: .followed,
                                statusSince: since, updatedAt: since)
        let other = AgentSession(id: "other", agent: .claudeCode, project: "B", status: .done,
                                 hasUnreadCompletion: true, statusSince: since, updatedAt: since)
        let idle = AgentSession(id: "idle", agent: .codex, project: "A", status: .done,
                                statusSince: since, updatedAt: since)
        let working = AgentSession(id: "working", agent: .codex, project: "A", status: .working,
                                   statusSince: since, updatedAt: since)
        let waiting = AgentSession(id: "waiting", agent: .codex, project: "A", status: .needsResponse,
                                   statusSince: since, updatedAt: since)
        let error = AgentSession(id: "error", agent: .codex, project: "A", status: .done,
                                 failed: true, statusSince: since, updatedAt: since)
        let dashboard = [done, other, idle, working, waiting, error]
        var schedule = CompletionReminderSchedule()
        #expect(schedule.due(dashboard, now: since).isEmpty)
        var prefs = MenuSessionPreferences()
        prefs.selectedAgents = [.codex]
        prefs.clear(dashboard, sourceID: "mac")
        #expect(prefs.visible(dashboard, sourceID: "mac") == [working, waiting, error])
        prefs.selectedAgents = Set(AgentKind.allCases)
        let restored = try JSONDecoder().decode(MenuSessionPreferences.self, from: JSONEncoder().encode(prefs))
        #expect(restored.visible(dashboard, sourceID: "mac") == [other, working, waiting, error])
        #expect(dashboard.count == 6)
        #expect(done.hasUnreadCompletion)
        #expect(schedule.due(dashboard, now: Date(timeIntervalSince1970: 300)).map(\.id) == ["done"])
        var next = done
        next.completionID = "turn-2"
        #expect(restored.visible([next], sourceID: "mac") == [next])
    }

}
