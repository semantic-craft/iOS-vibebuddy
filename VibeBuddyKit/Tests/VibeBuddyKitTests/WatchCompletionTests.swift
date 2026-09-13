import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Exact completion reading")
struct WatchCompletionTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func state(round: String = "round-1", unread: Bool = true) -> WatchDashboardState {
        var session = AgentSession(id: "task / ?", agent: .claudeCode, project: "Task",
            status: .done, hasUnreadCompletion: unread, attention: .followed,
            statusSince: date, updatedAt: date)
        session.completionID = round
        return WatchDashboardState(sourceID: "mac-a", pairingEpoch: "pair-1",
            followedTasks: [WatchFollowedTask(session)], relay: .live, observedAt: date)
    }
    var link: WatchTaskLink {
        WatchTaskLink(sourceID: "mac-a", pairingEpoch: "pair-1",
                      sessionID: "task / ?", completionID: "round-1")
    }
    @Test("Deep link stays bound to displayed source, task and completion")
    func linkIdentity() {
        #expect(WatchTaskLink(url: link.url) == link)
        #expect(link.task(in: state())?.sessionID == "task / ?")
        var other = state(); other.sourceID = "mac-b"
        #expect(link.task(in: other) == nil)
        other = state(); other.pairingEpoch = "pair-2"
        #expect(link.task(in: other) == nil)
        #expect(WatchTaskLink(url: URL(string: "vibebuddy://watch-task?source=a&source=b&epoch=e&session=s")!) == nil)
    }
    @Test("Reading offline survives restart and only the authority removes a result")
    func durableRead() throws {
        var queue = WatchCompletionQueue()
        var offline = state(); offline.relay = .disconnected
        queue.viewed(link, state: offline)
        queue.viewed(link, state: offline)
        #expect(queue.links == [link])
        queue = try JSONDecoder().decode(WatchCompletionQueue.self, from: JSONEncoder().encode(queue))
        queue.reconcile(with: state())
        #expect(queue.links == [link])
        queue.reconcile(with: state(unread: false))
        #expect(queue.links.isEmpty)
    }
    @Test("A stale click and an old queued read never acknowledge the newer round")
    func newerRound() {
        var queue = WatchCompletionQueue()
        queue.viewed(link, state: state(round: "round-2"))
        #expect(queue.links.isEmpty)
        queue.viewed(link, state: state())
        queue.reconcile(with: state(round: "round-2"))
        #expect(queue.links.isEmpty)
        #expect(state(round: "round-2").followedTasks.first?.presentation == .completeUnread)
    }

    @Test("A result evicted from the wrist window keeps its exact retry until a definitive receipt")
    func evictedResult() throws {
        var queue = WatchCompletionQueue()
        queue.viewed(link, state: state())
        var window = state()
        window.followedTasks = []
        window.results = (0..<6).map { index in
            var task = state().followedTasks[0]
            task.sessionID = "newer-\(index)"
            return task
        }
        queue.reconcile(with: window)
        queue = try JSONDecoder().decode(WatchCompletionQueue.self, from: JSONEncoder().encode(queue))
        #expect(queue.links == [link])
        queue.received(.failed, for: link)
        #expect(queue.links == [link])
        let otherRound = WatchTaskLink(sourceID: link.sourceID, pairingEpoch: link.pairingEpoch,
                                      sessionID: link.sessionID, completionID: "round-2")
        queue.received(.accepted, for: otherRound)
        #expect(queue.links == [link])
        queue.received(.alreadyAcknowledged, for: link)
        #expect(queue.links.isEmpty)
    }
}
