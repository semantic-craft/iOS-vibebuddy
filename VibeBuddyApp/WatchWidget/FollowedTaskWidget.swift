import SwiftUI
import WidgetKit
import VibeBuddyKit

struct FollowedTaskEntry: TimelineEntry {
    let date: Date
    let snapshot: WatchComplicationSnapshot?
}

struct FollowedTaskProvider: TimelineProvider {
    func placeholder(in context: Context) -> FollowedTaskEntry {
        FollowedTaskEntry(date: Date(), snapshot: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (FollowedTaskEntry) -> Void) {
        completion(FollowedTaskEntry(date: Date(), snapshot: WatchComplicationStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FollowedTaskEntry>) -> Void) {
        let now = Date()
        let snapshot = WatchComplicationStore.load()
        var entries = [FollowedTaskEntry(date: now, snapshot: snapshot)]
        if let snapshot {
            let expiry = snapshot.observedAt.addingTimeInterval(WatchDashboardState.staleAfter)
            if expiry > now { entries.append(FollowedTaskEntry(date: expiry, snapshot: snapshot)) }
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

struct FollowedTaskView: View {
    let entry: FollowedTaskEntry
    private var task: WatchFollowedTask? { entry.snapshot?.selectedTask }
    private var stale: Bool {
        guard let snapshot = entry.snapshot else { return false }
        return snapshot.relay != .live || entry.date.timeIntervalSince(snapshot.observedAt) >= WatchDashboardState.staleAfter
    }
    private var status: LocalizedStringKey {
        switch task?.presentation {
        case .requiresInput: "Needs response"
        case .error: "Error"
        case .completeUnread: "Done"
        case .thinking: "Working"
        default: "Followed tasks"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let task {
                HStack(spacing: 3) {
                    Image(systemName: task.presentation.symbolName)
                    Text(status).lineLimit(1).minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                    if let count = entry.snapshot?.otherCount, count > 0 {
                        Text("\(count) more").fixedSize()
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color(taskStatus: task.presentation.colorToken))
                .widgetAccentable()
                Text(task.title.isEmpty ? String(localized: "Unnamed task") : task.title)
                    .font(.headline).lineLimit(1)
                if stale, let snapshot = entry.snapshot {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.badge.exclamationmark")
                        Text(pending ? "Sync pending" : "Updated")
                        Text(snapshot.observedAt, style: .relative)
                    }.font(.caption2)
                } else if pending {
                    Text("Viewed — syncing with Mac").font(.caption2).lineLimit(1)
                } else {
                    Text(task.summary ?? String(localized: statusResource))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Followed tasks").font(.caption2)
                Text(emptyTitle).font(.headline).lineLimit(2)
                if stale, let snapshot = entry.snapshot {
                    HStack(spacing: 3) {
                        Text("Updated")
                        Text(snapshot.observedAt, style: .relative)
                    }.font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(taskURL)
        .accessibilityElement(children: .combine)
        .containerBackground(.fill.tertiary, for: .widget)
    }
    private var pending: Bool {
        guard let completionID = task?.completionID else { return false }
        return entry.snapshot?.pendingCompletionIDs.contains(completionID) == true
    }
    private var taskURL: URL? {
        guard let snapshot = entry.snapshot, let task,
              let sourceID = snapshot.sourceID, let epoch = snapshot.pairingEpoch else { return nil }
        return WatchTaskLink(sourceID: sourceID, pairingEpoch: epoch,
                             sessionID: task.sessionID, completionID: task.completionID).url
    }
    private var statusResource: LocalizedStringResource {
        switch task?.presentation {
        case .requiresInput: "Waiting for your response"
        case .error: "Task reported an error"
        case .completeUnread: "Open the app to view the result"
        default: "Task is running"
        }
    }
    private var emptyTitle: LocalizedStringKey {
        guard let snapshot = entry.snapshot, snapshot.sourceID != nil, snapshot.relay != .noData else {
            return "Waiting for iPhone"
        }
        return snapshot.tasks.isEmpty ? "No followed tasks" : "All results read"
    }
}

struct FollowedTaskWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchComplicationStore.kind, provider: FollowedTaskProvider()) {
            FollowedTaskView(entry: $0)
        }
        .configurationDisplayName("Followed tasks")
        .description("The followed task that needs your attention next.")
        .supportedFamilies([.accessoryRectangular])
    }
}

@main
struct VibeBuddyWatchWidgets: WidgetBundle {
    var body: some Widget {
        FollowedTaskWidget()
        QuotaWidget()
    }
}
