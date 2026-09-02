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
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(state.alerts.enumerated()), id: \.element.id) { index, alert in
                        row(alert, isTop: index == 0)
                    }
                    WatchFooter(state: state, now: now)
                }
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .navigationTitle("Waiting")
        }
    }

    private func row(_ alert: WatchAlert, isTop: Bool) -> some View {
        let accent = Color(taskStatus: TaskPresentationState.requiresInput.colorToken)
        return HStack(alignment: .top, spacing: 6) {
            Capsule()
                .fill(isTop ? accent : Color.secondary)
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: alert.agent.symbolName)
                        .font(.system(size: 9))
                    Text("\(alert.agent.shortName) · \(alert.project)")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(WatchFormat.duration(alert.waitedFor(now: now)))
                        .monospacedDigit()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    Image(systemName: alert.waitKind == .permission
                          ? "lock.shield.fill" : "questionmark")
                        .font(.system(size: 10, weight: .bold))
                    Text(alert.waitKind == .permission ? "Needs approval" : "Asked a question")
                        .font(.caption)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isTop ? accent : .secondary)

                if let request = alert.request {
                    Text(request)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
