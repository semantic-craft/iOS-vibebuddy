import SwiftUI
import VibeBuddyKit

/// Everything that is waiting, in the dashboard's own order.
///
/// The home screen gives the top alert the whole page; this is where the rest
/// live, so a second blocked session is never invisible. It exists only while
/// something is waiting — an empty Alerts page would be a permanent swipe
/// position that says nothing.
struct WatchAlertsView: View {
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    WatchConnectionBanner(connection: connection)
                    VStack(spacing: 0) {
                        ForEach(Array(state.alerts.enumerated()), id: \.element.id) { index, alert in
                            row(alert)
                            if index < state.alerts.count - 1 {
                                CompanionHairline(leading: WatchMetrics.dotLane)
                            }
                        }
                    }
                    WatchFooter(state: state, connection: connection, now: now)
                }
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .navigationTitle("Waiting")
        }
    }

    /// The home card's grammar in one row: dot, who is waiting and for how
    /// long, the summary, and the kind of wait. Order says which is on top.
    private func row(_ alert: WatchAlert) -> some View {
        let accent = CompanionPalette.status(.requiresInput)
        return HStack(alignment: .top, spacing: 6) {
            StatusDot(state: .requiresInput)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if alert.agent == .grokBot {
                        SVGPathShape(alert.agent.brandMark)
                            .fill(alert.agent.brandColor)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: alert.agent.symbolName)
                            .font(.system(size: 9))
                    }
                    Text("\(alert.agent.shortName) · \(alert.project)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(WatchFormat.duration(alert.waitedFor(now: now)))
                        .monospacedDigit()
                }
                .font(CompanionType.font(10))
                .foregroundStyle(CompanionPalette.ink2)

                Text(alert.summary ?? alert.request
                     ?? (alert.waitKind == .permission ? String(localized: "Needs approval") : String(localized: "Asked a question")))
                    .font(CompanionType.font(13, .semibold))
                    .foregroundStyle(CompanionPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(alert.waitKind == .permission ? "Needs approval" : "Asked a question")
                    .font(CompanionType.font(10, .medium))
                    .foregroundStyle(accent)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
