import Foundation
import VibeBuddyKit
import WidgetKit

/// App Group bridge between the iPhone app and its static Widget. The Mac-owned
/// unread state arrives in the normal snapshot; this cache only mirrors the
/// already-projected summary for WidgetKit's separate process.
enum WidgetSnapshotStore {
    static let appGroup = "group.com.vibebuddy.app"
    static let widgetKind = "VibeBuddyStatusWidget"
    private static let key = "task-presentation-snapshot"

    static func load() -> TaskPresentationSnapshot {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(TaskPresentationSnapshot.self, from: data)
        else { return TaskPresentationSnapshot() }
        return snapshot
    }

    static func save(sessions: [AgentSession]) {
        let snapshot = TaskPresentationSnapshot(sessions: sessions)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: key)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
    }
}
