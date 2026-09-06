import SwiftUI
import WidgetKit
import VibeBuddyKit

/// Circular and rectangular three-count faces. Same buckets and Companion
/// colours as the Watch home; colour is never the only signal.
struct WatchCountsComplicationView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var previewFamily: WidgetFamily?
    let state: WatchDashboardState?

    private var family: WidgetFamily { previewFamily ?? widgetFamily }
    private var placeholder: Bool { state?.showsComplicationPlaceholder ?? true }

    var body: some View {
        Group {
            if placeholder {
                empty
            } else if family == .accessoryCircular {
                circular
            } else {
                rectangular
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 2) {
            Image(systemName: "iphone.gen3.slash")
            Text("Waiting for iPhone")
                .font(family == .accessoryCircular ? .caption2 : .headline)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(family == .accessoryCircular ? 2 : 2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for iPhone")
    }

    private var circular: some View {
        let slots = Self.slots(state?.counts ?? WatchSessionCounts())
        return VStack(spacing: 1) {
            ForEach(slots) { slot in
                HStack(spacing: 3) {
                    Image(systemName: slot.state.symbolName)
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 9)
                    Text(slot.value, format: .number)
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                }
                .foregroundStyle(slot.tint)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.voice(slots))
    }

    private var rectangular: some View {
        let slots = Self.slots(state?.counts ?? WatchSessionCounts())
        return HStack(spacing: 8) {
            ForEach(slots) { slot in
                VStack(spacing: 1) {
                    Image(systemName: slot.state.symbolName)
                        .font(.system(size: 10, weight: .bold))
                    Text(slot.value, format: .number)
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    Text(slot.title)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundStyle(slot.tint)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(slot.title))
                .accessibilityValue(Text(slot.value, format: .number))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private struct Slot: Identifiable {
        var id: TaskPresentationState { state }
        let state: TaskPresentationState
        let value: Int
        let title: LocalizedStringResource
        var tint: Color {
            value > 0 ? CompanionPalette.status(state) : Color.secondary
        }
    }

    private static func slots(_ counts: WatchSessionCounts) -> [Slot] {
        [
            Slot(state: .requiresInput, value: counts.needsResponse, title: "Needs you"),
            Slot(state: .thinking, value: counts.working, title: "Working"),
            Slot(state: .completeUnread, value: counts.done, title: "Done"),
        ]
    }

    private static func voice(_ slots: [Slot]) -> String {
        slots.map { "\($0.value) \(String(localized: $0.title))" }.joined(separator: ", ")
    }
}
