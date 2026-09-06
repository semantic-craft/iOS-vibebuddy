import SwiftUI
import WidgetKit
import RelevanceKit
import VibeBuddyKit

struct CountsEntry: TimelineEntry {
    let date: Date
    let state: WatchDashboardState?

    var relevance: TimelineEntryRelevance? {
        TimelineEntryRelevance(score: state?.smartStackScore(now: date) ?? 0)
    }
}

struct CountsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CountsEntry {
        CountsEntry(date: Date(), state: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (CountsEntry) -> Void) {
        if context.isPreview {
            completion(CountsEntry(date: Date(), state: WatchDemoScenario.permission.state(now: Date())))
            return
        }
        completion(CountsEntry(date: Date(), state: WatchDashboardStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CountsEntry>) -> Void) {
        let now = Date()
        let state = WatchDashboardStore.load()
        var entries = [CountsEntry(date: now, state: state)]
        if let state, !state.showsComplicationPlaceholder {
            let expiry = state.observedAt.addingTimeInterval(WatchDashboardState.staleAfter)
            if expiry > now {
                entries.append(CountsEntry(date: expiry, state: state))
            }
        }
        completion(Timeline(entries: entries, policy: .never))
    }

    @available(watchOS 11.0, *)
    func relevance() async -> WidgetRelevance<Void> {
        let now = Date()
        guard let state = WatchDashboardStore.load(),
              state.smartStackScore(now: now) > 0
        else { return WidgetRelevance([]) }
        let end = now.addingTimeInterval(WatchDashboardState.staleAfter)
        return WidgetRelevance([
            WidgetRelevanceAttribute(context: .date(from: now, to: end)),
        ])
    }
}

@main
struct VibeBuddyWatchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchDashboardStore.kind, provider: CountsProvider()) { entry in
            WatchCountsComplicationView(state: entry.state)
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        }
        .configurationDisplayName("Sessions")
        .description("needsResponse, working, and done counts.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

#Preview("Circular", as: .accessoryCircular) {
    VibeBuddyWatchWidget()
} timeline: {
    CountsEntry(date: .now, state: WatchDemoScenario.permission.state(now: .now))
    CountsEntry(date: .now, state: nil)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    VibeBuddyWatchWidget()
} timeline: {
    CountsEntry(date: .now, state: WatchDemoScenario.permission.state(now: .now))
    CountsEntry(date: .now, state: nil)
}
