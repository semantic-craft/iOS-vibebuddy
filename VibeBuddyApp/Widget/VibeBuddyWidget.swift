import WidgetKit
import SwiftUI
import ActivityKit
import VibeBuddyKit

private let assignedStates: [TaskPresentationState] = [
    .error, .requiresInput, .thinking, .completeUnread, .idle,
]

@main
struct VibeBuddyWidgetBundle: WidgetBundle {
    var body: some Widget {
        VibeBuddyStatusWidget()
        VibeBuddyLiveActivity()
    }
}

private struct StatusEntry: TimelineEntry {
    let date: Date
    let snapshot: TaskPresentationSnapshot
}

private struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: Date(), snapshot: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: Date(), snapshot: context.isPreview ? Self.sample : WidgetSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let snapshot = WidgetSnapshotStore.load()
        let entry = StatusEntry(date: snapshot.updatedAt, snapshot: snapshot)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private static let sample = TaskPresentationSnapshot(
        summary: TaskPresentationSummary(idle: 1, thinking: 1, completeUnread: 1,
                                         requiresInput: 1, error: 1),
        topProject: "release-check", topSessionId: "demo-error")
}

struct VibeBuddyStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: StatusProvider()) { entry in
            StatusWidgetView(snapshot: entry.snapshot)
                .containerBackground(.background, for: .widget)
                .widgetURL(entry.snapshot.topSessionId.flatMap(activitySessionURL(id:)))
        }
        .configurationDisplayName("Task status")
        .description("See the highest-priority task and the shared VibeBuddy status summary.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

private struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: TaskPresentationSnapshot

    var body: some View {
        if snapshot.summary.isEmpty {
            emptyContent
        } else if family == .accessoryRectangular {
            accessoryContent
        } else {
            systemSmallContent
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "rectangle.stack")
                .font(.title2)
            Text(TaskPresentationState.unassigned.label)
                .font(.headline)
            Text("Start a task to see its status.")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private var systemSmallContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ActivityCat(state: snapshot.summary.primaryState, size: 34)
                    .padding(5)
                    .background(.black, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.summary.primaryState.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color(taskStatus: snapshot.summary.primaryState.colorToken))
                    Text(snapshot.topProject ?? "vibebuddy")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                ForEach(assignedStates, id: \.self) { state in
                    VStack(spacing: 2) {
                        TaskStatusIndicator(state, size: 8)
                        Text("\(snapshot.summary.count(for: state))")
                            .font(.caption2.monospacedDigit())
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(snapshot.summary.count(for: state)) \(state.label)")
                }
            }
        }
        .padding(2)
    }

    private var accessoryContent: some View {
        HStack(spacing: 8) {
            TaskStatusIndicator(snapshot.summary.primaryState, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.topProject ?? snapshot.summary.primaryState.label)
                    .font(.headline)
                    .lineLimit(1)
                Text(accessorySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var accessorySummary: String {
        if snapshot.summary.isEmpty { return TaskPresentationState.unassigned.label }
        return assignedStates
            .filter { snapshot.summary.count(for: $0) > 0 }
            .map { "\(snapshot.summary.count(for: $0)) \($0.label.lowercased())" }
            .joined(separator: " · ")
    }
}

struct VibeBuddyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VibeBuddyActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding()
                .activityBackgroundTint(Color.black.opacity(0.5))
                .widgetURL(tapTarget(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityCat(state: context.state.summary.primaryState, size: 40)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(Array(nonzeroStates(context.state).prefix(3)), id: \.self) { state in
                            counter(context.state.summary.count(for: state), state)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    let state = context.state.summary.primaryState
                    HStack(spacing: 5) {
                        Image(systemName: state.symbolName)
                        Text(context.state.topProject.map { "\(state.label) · \($0)" } ?? state.label)
                    }
                    .font(.caption)
                    .foregroundStyle(Color(taskStatus: state.colorToken))
                    .widgetURL(tapTarget(context.state))
                }
            } compactLeading: {
                let state = context.state.summary.primaryState
                Image(systemName: state.symbolName)
                    .foregroundStyle(Color(taskStatus: state.colorToken))
                    .accessibilityLabel(state.label)
            } compactTrailing: {
                let state = context.state.summary.primaryState
                Text("\(context.state.summary.count(for: state))")
                    .monospacedDigit()
                    .foregroundStyle(Color(taskStatus: state.colorToken))
                    .accessibilityLabel("\(context.state.summary.count(for: state)) \(state.label)")
            } minimal: {
                TaskStatusIndicator(context.state.summary.primaryState, size: 10)
            }
        }
    }
}

@MainActor
private func counter(_ value: Int, _ state: TaskPresentationState) -> some View {
    HStack(spacing: 5) {
        TaskStatusIndicator(state, size: 9)
        Image(systemName: state.symbolName)
        Text("\(value)").monospacedDigit()
    }
    .foregroundStyle(Color(taskStatus: state.colorToken))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(value) \(state.label)")
}

private func nonzeroStates(_ state: VibeBuddyActivityAttributes.ContentState) -> [TaskPresentationState] {
    assignedStates.filter { state.summary.count(for: $0) > 0 }
}

/// The deep link a tap should follow: the focused session if we have one, else
/// `nil` so the activity just opens the app.
private func tapTarget(_ state: VibeBuddyActivityAttributes.ContentState) -> URL? {
    state.topSessionId.flatMap(activitySessionURL(id:))
}

struct LockScreenView: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            ActivityCat(state: state.summary.primaryState, size: 40)
            HStack(spacing: 10) {
                ForEach(nonzeroStates(state), id: \.self) { status in
                    counter(state.summary.count(for: status), status)
                }
            }
            Spacer()
            if let project = state.topProject {
                Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.headline)
    }
}
