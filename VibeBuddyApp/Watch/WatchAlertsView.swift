import SwiftUI
import VibeBuddyKit

/// Everything that is waiting, in the dashboard's own order.
///
/// The home screen gives the top alert the whole page and lists the rest as
/// rows; this page is the same list with nothing else on it, for the moment
/// when three things are waiting and the card is in the way. Every row opens
/// its session. It exists only while more than one session is waiting — an
/// empty Waiting page would be a permanent swipe position that says nothing.
struct WatchAlertsView: View {
    @ObservedObject var store: WatchStateStore
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    WatchConnectionBanner(connection: connection)
                    VStack(spacing: 0) {
                        ForEach(state.alerts) { alert in
                            WatchSessionRow(state: .requiresInput,
                                            title: WatchSessionRow.title(for: alert),
                                            detail: "\(alert.agent.shortName) · \(alert.project) · \(kind(alert))",
                                            trailing: WatchFormat.duration(alert.waitedFor(now: now))) {
                                store.openSession(alert.sessionId)
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

    private func kind(_ alert: WatchAlert) -> String {
        alert.waitKind == .permission ? String(localized: "Needs approval") : String(localized: "Asked a question")
    }
}
