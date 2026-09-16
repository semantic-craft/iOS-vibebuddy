import AppKit
import Combine
import VibeBuddyKit

@main
struct PublicationProbe {
    @MainActor static func main() {
        _ = NSApplication.shared
        let model = MenuBarModel(runtimeEnabled: false)
        var publications = 0
        let observer = model.objectWillChange.sink { publications += 1 }
        let now = Date()
        var snapshot = Snapshot(sessions: [], serverTime: now, sourceID: "publication-probe")
        model.applySnapshot(snapshot, observedAt: now)
        publications = 0
        for _ in 0..<100 { model.applySnapshot(snapshot, observedAt: Date()) }
        print("unchanged_snapshots=100 publications=\(publications)")
        let unchanged = publications
        snapshot.recentDirectories = ["/isolated/project"]
        publications = 0
        model.applySnapshot(snapshot, observedAt: Date())
        precondition(model.recentDirectories == snapshot.recentDirectories && publications > 0)
        print("changed_snapshot_published=true")
        model.applySnapshot(snapshot, observedAt: Date().addingTimeInterval(-20))
        precondition(!model.recapAuthorityAvailable)
        publications = 0
        model.applySnapshot(snapshot, observedAt: Date())
        precondition(model.recapAuthorityAvailable && publications > 0)
        print("expired_authority_restored_and_published=true")
        snapshot.sourceID = nil
        model.applySnapshot(snapshot, observedAt: Date())
        precondition(!model.recapAuthorityAvailable)
        print("missing_authority_disabled=true")
        snapshot.sourceID = "publication-probe"
        let old = now.addingTimeInterval(-SessionCurrency.window + 1)
        snapshot.sessions = [AgentSession(id: "aging", agent: .codex, project: "isolated",
                                         status: .done, statusSince: old, updatedAt: old)]
        model.applySnapshot(snapshot, observedAt: now)
        publications = 0
        model.applySnapshot(snapshot, observedAt: now.addingTimeInterval(2))
        precondition(publications > 0)
        print("current_to_older_boundary_published=true")
        let waitingSince = now.addingTimeInterval(-179)
        snapshot.sessions = [AgentSession(id: "waiting", agent: .codex, project: "isolated",
                                         status: .needsResponse, waitKind: .permission,
                                         statusSince: waitingSince, updatedAt: now)]
        model.applySnapshot(snapshot, observedAt: now)
        publications = 0
        model.applySnapshot(snapshot, observedAt: now.addingTimeInterval(2))
        precondition(publications > 0)
        print("long_wait_boundary_published=true")
        withExtendedLifetime(observer) {}
        if ProcessInfo.processInfo.environment["EXPECT_DEDUP"] == "1" { precondition(unchanged == 0) }
        exit(0)
    }
}
