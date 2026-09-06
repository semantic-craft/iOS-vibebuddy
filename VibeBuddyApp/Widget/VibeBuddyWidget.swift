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
                .containerBackground(CompanionPalette.bg, for: .widget)
                .widgetURL(entry.snapshot.topSessionId.flatMap(activitySessionURL(id:)))
        }
        .configurationDisplayName("Task status")
        .description("See the highest-priority task and the shared VibeBuddy status summary.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

/// Home-screen widget: the cat says one line, the second line carries the
/// rest, and the top session sits underneath (Companion, round 5).
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
            ActivityCat(state: .unassigned, size: 34)
            Text("All quiet")
                .font(CompanionType.font(14, .black))
            Text("Start a task to see its status.")
                .font(CompanionType.font(11, .semibold))
        }
        .foregroundStyle(CompanionPalette.ink2)
        .accessibilityElement(children: .combine)
    }

    private var systemSmallContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ActivityCat(state: snapshot.summary.primaryState, size: 36, onDark: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(CompanionCopy.moodLine(snapshot.summary))
                        .font(CompanionType.font(13, .black))
                        .foregroundStyle(CompanionPalette.ink)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(CompanionCopy.restLine(snapshot.summary))
                        .font(CompanionType.font(10, .bold))
                        .foregroundStyle(CompanionPalette.ink2)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            TopSessionLine(snapshot: snapshot, onDark: false)
        }
        .padding(2)
    }

    private var accessoryContent: some View {
        HStack(spacing: 8) {
            TaskStatusIndicator(snapshot.summary.primaryState, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(CompanionCopy.moodLine(snapshot.summary))
                    .font(.headline)
                    .lineLimit(1)
                Text(snapshot.topProject ?? CompanionCopy.restLine(snapshot.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The session that leads the snapshot: state glyph, project, primary state.
private struct TopSessionLine: View {
    let snapshot: TaskPresentationSnapshot
    var onDark: Bool

    var body: some View {
        let primary = snapshot.summary.primaryState
        HStack(spacing: 8) {
            StateGlyph(state: primary, size: 22, onDark: onDark)
            VStack(alignment: .leading, spacing: 0) {
                Text(snapshot.topProject ?? "vibebuddy")
                    .font(CompanionType.font(12, .heavy))
                    .foregroundStyle(onDark ? .white : CompanionPalette.ink)
                    .lineLimit(1)
                Text(primary.label)
                    .font(CompanionType.font(9, .heavy)).textCase(.uppercase).kerning(0.5)
                    .foregroundStyle(CompanionPalette.status(primary))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct VibeBuddyLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: VibeBuddyActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding()
                .activityBackgroundTint(Color(hex: 0x2B3247).opacity(0.85))
                .widgetURL(tapTarget(context.state))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityCat(state: context.state.summary.primaryState, size: 40)
                }
                DynamicIslandExpandedRegion(.center) {
                    ActivityHeadline(state: context.state)
                        .widgetURL(tapTarget(context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityBottom(state: context.state)
                        .padding(.top, 4)
                }
            } compactLeading: {
                ActivityCat(state: context.state.summary.primaryState, size: 22)
            } compactTrailing: {
                NeedsYouBadge(summary: context.state.summary)
            } minimal: {
                TaskStatusIndicator(context.state.summary.primaryState, size: 10)
            }
        }
    }
}

/// Round 5, compact: only the needs-you count, in the state colour that
/// earns it; a quiet snapshot shows the working count in blue instead.
private struct NeedsYouBadge: View {
    let summary: TaskPresentationSummary

    var body: some View {
        let needs = CompanionCopy.needsYou(summary)
        let value = needs > 0 ? needs : summary.thinking
        let state: TaskPresentationState = summary.error > 0 ? .error : (needs > 0 ? .requiresInput : .thinking)
        Text("\(value)")
            .font(CompanionType.font(12, .black).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background(CompanionPalette.status(state), in: Capsule())
            .accessibilityLabel(needs > 0 ? "\(needs) need you" : "\(value) working")
    }
}

/// The deep link a tap should follow: the focused session if we have one, else
/// `nil` so the activity just opens the app.
private func tapTarget(_ state: VibeBuddyActivityAttributes.ContentState) -> URL? {
    state.topSessionId.flatMap(activitySessionURL(id:))
}

/// The cat's line and the rest, shared by the lock screen banner and the
/// expanded Dynamic Island so both read the same.
struct ActivityHeadline: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CompanionCopy.moodLine(state.summary))
                .font(CompanionType.font(15, .black))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            let rest = CompanionCopy.restLine(state.summary)
            if !rest.isEmpty {
                Text(rest)
                    .font(CompanionType.font(11, .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Lock screen banner: cat + the shared headline, the leading session beneath.
struct LockScreenView: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ActivityCat(state: state.summary.primaryState, size: 40)
                ActivityHeadline(state: state)
                Spacer(minLength: 0)
            }
            ActivityBottom(state: state)
        }
    }
}

/// Under the headline: the request with its two keys while the leading
/// session waits on an approval (island-approve/01), else the leading session.
private struct ActivityBottom: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        if let id = state.approvalId {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    StateGlyph(state: .requiresInput, size: 22, onDark: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.approvalTitle ?? state.topProject ?? "Approval")
                            .font(CompanionType.font(12, .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let detail = state.approvalDetail {
                            Text(detail)
                                .font(CompanionType.mono(10))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if let sent = state.decisionSent {
                    Text(sent == "failed"
                         ? "Couldn't reach your Mac — open the app."
                         : "Sent · waiting for your Mac")
                        .font(CompanionType.font(11, .bold))
                        .foregroundStyle(.white.opacity(0.7))
                } else {
                    HStack(spacing: 8) {
                        Button(intent: IslandDecisionIntent(approvalId: id, allow: true)) {
                            IslandKey(title: "Approve", tint: CompanionPalette.status(.completeUnread))
                        }
                        Button(intent: IslandDecisionIntent(approvalId: id, allow: false)) {
                            IslandKey(title: "Deny", tint: CompanionPalette.status(.error))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            TopSessionLine(snapshot: TaskPresentationSnapshot(summary: state.summary,
                                                              topProject: state.topProject,
                                                              topSessionId: state.topSessionId),
                           onDark: true)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// One of the two equal keys (round 4, glance variant 2), drawn as a label so
/// it works inside a widget `Button(intent:)`.
private struct IslandKey: View {
    let title: LocalizedStringKey
    let tint: Color
    var body: some View {
        Text(title)
            .font(CompanionType.font(14, .heavy))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(tint, in: Capsule())
    }
}
