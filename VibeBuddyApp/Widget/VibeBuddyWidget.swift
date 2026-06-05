import WidgetKit
import SwiftUI
import ActivityKit

@main
struct VibeBuddyWidgetBundle: WidgetBundle {
    var body: some Widget {
        VibeBuddyLiveActivity()
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
                    ActivityPixelCat(mood: mood(context.state), size: 40)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        counter(context.state.needsResponse, "exclamationmark.circle.fill", .orange)
                        counter(context.state.working, "hourglass", .blue)
                        counter(context.state.done, "checkmark.circle.fill", .green)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Group {
                        if let project = context.state.topProject {
                            Text("Needs you · \(project)").font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("\(context.state.done) done").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .widgetURL(tapTarget(context.state))
                }
            } compactLeading: {
                Image(systemName: context.state.needsResponse > 0
                      ? "bell.badge.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(context.state.needsResponse > 0 ? .orange : .secondary)
            } compactTrailing: {
                if context.state.needsResponse > 0 {
                    Text("\(context.state.needsResponse)").monospacedDigit().foregroundStyle(.orange)
                } else {
                    Text("\(context.state.working)").monospacedDigit().foregroundStyle(.blue)
                }
            } minimal: {
                Text("\(context.state.needsResponse)").monospacedDigit()
                    .foregroundStyle(context.state.needsResponse > 0 ? .orange : .secondary)
            }
        }
    }
}

private func counter(_ value: Int, _ symbol: String, _ color: Color) -> some View {
    Label("\(value)", systemImage: symbol).monospacedDigit().foregroundStyle(color)
}

private func mood(_ state: VibeBuddyActivityAttributes.ContentState) -> ActivityMood {
    ActivityMood.from(needsResponse: state.needsResponse, working: state.working, done: state.done)
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
            ActivityPixelCat(mood: mood(state), size: 40)
            HStack(spacing: 18) {
                counter(state.needsResponse, "exclamationmark.circle.fill", .orange)
                counter(state.working, "hourglass", .blue)
                counter(state.done, "checkmark.circle.fill", .green)
            }
            Spacer()
            if let project = state.topProject {
                Text(project).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.headline)
    }
}
