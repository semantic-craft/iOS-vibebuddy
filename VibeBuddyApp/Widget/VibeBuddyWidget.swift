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
                .activityBackgroundTint(Color.black.opacity(0.78))
                .widgetURL(tapTarget(context.state))
        } dynamicIsland: { context in
            // Expanded: one dominant value (the primary state's count) on the
            // trailing side, the cat as its emotional mirror on the leading
            // side, and all reading text in the bottom band. Nothing is placed
            // in the top corners beyond what the island's own margins allow.
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityCat(state: context.state.summary.primaryState, size: 52)
                        .padding(.leading, 4)
                        .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Headline(state: context.state)
                        .padding(.trailing, 4)
                        .padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Detail(state: context.state)
                        .widgetURL(tapTarget(context.state))
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ActivityCat(state: context.state.summary.primaryState, size: 22)
                    .padding(.leading, 2)
                    .accessibilityLabel(context.state.summary.primaryState.label)
            } compactTrailing: {
                let state = context.state.summary.primaryState
                Text("\(context.state.summary.count(for: state))")
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Color(taskStatus: state.colorToken))
                    .padding(.trailing, 2)
                    .accessibilityLabel("\(context.state.summary.count(for: state)) \(state.label)")
            } minimal: {
                TaskStatusIndicator(context.state.summary.primaryState, size: 10)
            }
            .widgetURL(tapTarget(context.state))
        }
    }
}

/// The one number worth glancing at: how many sessions are in the primary
/// state. The symbol carries the status colour; the numeral stays white so
/// colour means "signal", never "text".
private struct Headline: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        let primary = state.summary.primaryState
        let count = state.summary.count(for: primary)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: primary.symbolName)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color(taskStatus: primary.colorToken))
            Text("\(count)")
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(primary.label)")
    }
}

/// Reading text for the expanded island and the lock screen: what and where
/// on the first line, the full distribution on the second. The second line is
/// dropped when it would only repeat the headline.
private struct Detail: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        let primary = state.summary.primaryState
        let states = nonzeroStates(state)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(primary.label)
                    .foregroundStyle(Color(taskStatus: primary.colorToken))
                if let project = state.topProject {
                    Text("·").foregroundStyle(.secondary)
                    Text(project)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.subheadline.weight(.semibold))
            if states.count > 1 {
                HStack(spacing: 14) {
                    ForEach(states, id: \.self) { status in
                        counter(state.summary.count(for: status), status)
                    }
                }
                .font(.caption.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private func counter(_ value: Int, _ state: TaskPresentationState) -> some View {
    HStack(spacing: 4) {
        Image(systemName: state.symbolName)
            .foregroundStyle(Color(taskStatus: state.colorToken))
        Text("\(value)")
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(value) \(state.label)")
}

/// One state's count: the shared status dot plus a digit. The dot already
/// carries the state (and swaps to a symbol under Differentiate Without Color),
/// so no second glyph. The digit stays neutral so several counts read as one
/// row, and the dot scales with the digit under Dynamic Type.
private struct StateCount: View {
    let value: Int
    let state: TaskPresentationState
    @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 9

    var body: some View {
        HStack(spacing: 4) {
            TaskStatusIndicator(state, size: dotSize)
            Text("\(value)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(state.label)")
    }
}

private func nonzeroStates(_ state: VibeBuddyActivityAttributes.ContentState) -> [TaskPresentationState] {
    assignedStates.filter { state.summary.count(for: $0) > 0 }
}

/// The deep link a tap should follow: the focused session if we have one, else
/// `nil` so the activity just opens the app.
private func tapTarget(_ state: VibeBuddyActivityAttributes.ContentState) -> URL? {
    state.topSessionId.flatMap(activitySessionURL(id:))
}

/// Project name over the primary state, in that state's color. Shared by the
/// lock screen banner and the expanded Dynamic Island so both read the same.
struct ActivityHeadline: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        let primary = state.summary.primaryState
        let count = state.summary.count(for: primary)
        VStack(alignment: .leading, spacing: 3) {
            Text(state.topProject ?? "VibeBuddy")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Image(systemName: primary.symbolName)
                    .font(.caption2.weight(.bold))
                Text("\(primary.label) · \(count) \(count == 1 ? "session" : "sessions")")
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(Color(taskStatus: primary.colorToken))
        }
    }
}

/// Lock screen banner: the shared headline on the left, a dot-plus-digit strip
/// for every non-zero state on the right.
struct LockScreenView: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ActivityCat(state: state.summary.primaryState, size: 48)
            Detail(state: state)
            Headline(state: state)
        }
    }
}
