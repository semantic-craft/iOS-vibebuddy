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
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    counter(context.state.needsResponse, "exclamationmark.circle.fill", .orange)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    counter(context.state.working, "hourglass", .blue)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let project = context.state.topProject {
                        Text("需回应 · \(project)").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("\(context.state.done) 已完成").font(.caption).foregroundStyle(.secondary)
                    }
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

struct LockScreenView: View {
    let state: VibeBuddyActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 18) {
            counter(state.needsResponse, "exclamationmark.circle.fill", .orange)
            counter(state.working, "hourglass", .blue)
            counter(state.done, "checkmark.circle.fill", .green)
            Spacer()
            if let project = state.topProject {
                Text(project).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.headline)
    }
}
