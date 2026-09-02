import SwiftUI
import VibeBuddyKit

struct WatchRootView: View {
    let launch: WatchLaunch
    @State private var page: WatchPage

    init(launch: WatchLaunch) {
        self.launch = launch
        _page = State(initialValue: launch.initialPage)
    }

    var body: some View {
        if launch.state.relay == .noData {
            WatchNoDataView()
        } else {
            TabView(selection: $page) {
                WatchHomeView(state: launch.state, now: launch.now)
                    .tag(WatchPage.home)
                WatchQuotaView(state: launch.state, now: launch.now)
                    .tag(WatchPage.quota)
            }
            .tabViewStyle(.page)
        }
    }
}

/// The Watch has never been told anything. Say that, and say what to do about
/// it — a placeholder percentage here would be a lie about someone's account.
struct WatchNoDataView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    WatchPixelCat(state: .sleeping)
                    Text("Waiting for iPhone")
                        .font(.headline)
                    Text("Open vibebuddy on your iPhone and pair it with your Mac. Sessions and weekly quota appear here.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .navigationTitle("vibebuddy")
        }
    }
}

/// One line of honesty at the bottom of every page: how current this is, and
/// whether any of it is real.
struct WatchFooter: View {
    let state: WatchDashboardState
    let now: Date

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: state.relay == .live ? "iphone.gen3" : "iphone.gen3.slash")
                    .font(.system(size: 9))
                Text(relayText)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if state.isDemo {
                Text("Sample data")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.top, 2)
    }

    private var relayText: String {
        switch state.relay {
        case .live:
            return WatchFormat.updated(state.age(now: now))
        case .disconnected:
            return String(localized: "Disconnected · \(WatchFormat.duration(state.age(now: now))) old")
        case .noData:
            return String(localized: "No data")
        }
    }
}
