import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Followed task complication")
struct WatchFollowedTaskTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func session(_ id: String, _ status: SessionStatus, since: TimeInterval = 0,
                         unread: Bool = false, followed: Bool = true, agent: AgentKind = .claudeCode) -> AgentSession {
        AgentSession(id: id, agent: agent, project: id, status: status,
            hasUnreadCompletion: unread, attention: followed ? .followed : .normal,
            statusSince: now.addingTimeInterval(since), updatedAt: now)
    }
    private func projection(_ sessions: [AgentSession]) -> WatchDashboardState {
        WatchDashboardProjection.make(snapshot: Snapshot(sessions: sessions, serverTime: now, sourceID: "mac-a"),
            quotas: [], relay: .live, now: now)
    }

    @Test("Completion persists through passive snapshots and waiting work preempts it")
    func progression() {
        var a = session("a", .working)
        var b = session("b", .working, since: 1)
        let c = session("c", .needsResponse, followed: false)
        var state = projection([a,b,c])
        #expect(WatchComplicationSnapshot(state: state).selectedTask?.sessionID == "a")
        a.status = .done; a.hasUnreadCompletion = true
        state = projection([a,b,c])
        #expect(WatchComplicationSnapshot(state: state).selectedTask?.presentation == .completeUnread)
        #expect(WatchComplicationSnapshot(state: state).otherCount == 1)
        b.status = .needsResponse
        #expect(WatchComplicationSnapshot(state: projection([a,b,c])).selectedTask?.sessionID == "b")
        b.status = .working
        #expect(WatchComplicationSnapshot(state: projection([a,b,c])).selectedTask?.sessionID == "a")
        a.hasUnreadCompletion = false
        #expect(WatchComplicationSnapshot(state: projection([a,b,c])).selectedTask?.sessionID == "b")
    }

    @Test("Stable running selection, identity and actual observation survive the compact cache")
    func cache() throws {
        let a = session("a", .working, since: 1)
        let b = session("b", .working)
        let prior = WatchComplicationSnapshot(state: projection([a]))
        let next = WatchComplicationSnapshot(state: projection([a,b]), previous: prior)
        #expect(next.selectedTask?.sessionID == "a")
        #expect(next.observedAt == now)
        let restored = try JSONDecoder().decode(WatchComplicationSnapshot.self, from: JSONEncoder().encode(next))
        #expect(restored == next)
        var changed = projection([a,b]); changed.sourceID = "mac-b"
        #expect(WatchComplicationSnapshot(state: changed, previous: prior).selectedTask?.sessionID == "b")
    }

    @Test("Detail changes relay even at equal counts, with no raw request in compact data")
    func detailChanges() throws {
        var a = session("a", .needsResponse)
        a.summary = "cat /private/secret"
        let original = projection([a])
        a.name = "A real title"
        let changed = projection([a])
        #expect(!original.isEquivalent(to: changed))
        #expect(changed.followedTasks.first?.summary == nil)
        #expect(changed.followedTasks.first?.title == "A real title")
        #expect(projection([]).followedTasks.isEmpty)
        #expect(!projection([session("a", .done)]).followedTasks.isEmpty)
    }
    @Test("Same-title agents survive phone transport and atomic app/widget recovery")
    func sourceRoundTrip() throws {
        let agents: [AgentKind] = [.grokBot, .grok, .claudeCode, .codex]
        let sessions = agents.map { agent in
            var value = session(agent.rawValue, .done, unread: true, agent: agent)
            value.name = "Same task"
            value.completionID = "round-1"
            value.summary = "Finished"
            return value
        }
        var projected = projection(sessions)
        projected.pairingEpoch = "pair-1"
        projected.relayRevision = 1
        let relayed = try JSONDecoder().decode(WatchDashboardState.self,
            from: JSONEncoder().encode(projected))
        let data = try JSONEncoder().encode(WatchStoredState(state: relayed, queue: WatchCompletionQueue()))
        let restored = try #require(WatchStoredState.decode(data))
        #expect(restored.state.followedTasks.map(\.agent) == agents.map(Optional.some))
        #expect(restored.complication.tasks.map(\.sourceName) == ["Grok Bot", "Grok Build", "Claude Code", "Codex"])
        #expect(restored.state.followedTasks.allSatisfy { $0.title == "Same task" && $0.completionID == "round-1" })
        #expect(restored.state.followedTasks == projected.followedTasks)
        // Old paired clients omitted this field in both copies of the atomic cache.
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (container, key) in [("state", "followedTasks"), ("complication", "tasks")] {
            var object = try #require(json[container] as? [String: Any])
            var tasks = try #require(object[key] as? [[String: Any]])
            for index in tasks.indices { tasks[index].removeValue(forKey: "agent") }
            object[key] = tasks
            json[container] = object
        }
        let old = try #require(WatchStoredState.decode(JSONSerialization.data(withJSONObject: json)))
        #expect(old.state.followedTasks.allSatisfy { $0.agent == nil && $0.sourceName == "Unknown source" })
        #expect(old.complication.tasks.map(\.sourceName) == old.state.followedTasks.map(\.sourceName))
        #expect(old.state.followedTasks.map(\.completionID) == projected.followedTasks.map(\.completionID))
    }

    @Test("A source correction alone republishes an otherwise identical followed task")
    func sourceChangesRelay() {
        let original = projection([session("same", .working, agent: .grok)])
        #expect(!original.isEquivalent(to: projection([session("same", .working, agent: .grokBot)])))
    }

}
