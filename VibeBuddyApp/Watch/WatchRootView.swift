import SwiftUI
import VibeBuddyKit

struct WatchRootView: View {
    @ObservedObject var store: WatchStateStore
    @State private var page: WatchPage

    init(store: WatchStateStore) {
        self.store = store
        _page = State(initialValue: store.initialPage)
    }

    var body: some View {
        // Demo Mode reads a frozen clock so a given launch input always produces
        // the same screen. Live state ages against the real one, which is the
        // whole point of showing how old it is.
        if store.isDemo {
            pages(now: store.launchedAt)
        } else {
            TimelineView(.periodic(from: store.launchedAt, by: 5)) { context in
                pages(now: context.date)
            }
        }
    }

    @ViewBuilder
    private func pages(now: Date) -> some View {
        // One verdict per render, derived once from the clock this pass is
        // drawing with, so every page agrees about which link is down.
        let connection = store.state?.connection(now: now, phoneReachable: store.isPhoneReachable) ?? .noData
        if let state = store.state, connection != .noData {
            TabView(selection: $page) {
                WatchHomeView(store: store, state: state, connection: connection, now: now)
                    .tag(WatchPage.home)
                if state.alerts.count > 1 {
                    WatchAlertsView(state: state, connection: connection, now: now)
                        .tag(WatchPage.alerts)
                }
                WatchQuotaView(state: state, connection: connection, now: now)
                    .tag(WatchPage.quota)
            }
            .tabViewStyle(.page)
            // The last waiting session was resolved while its page was open.
            .onChange(of: state.alerts.count) { _, count in
                if count <= 1, page == .alerts { page = .home }
            }
        } else {
            WatchNoDataView()
        }
    }
}

/// The Watch has never been told anything. Say that, and say what to do about
/// it — a placeholder percentage here would be a lie about someone's account.
struct WatchNoDataView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(CompanionPalette.ink3)
                        .accessibilityHidden(true)
                    Text("Waiting for iPhone")
                        .font(CompanionType.font(14, .semibold))
                        .foregroundStyle(CompanionPalette.ink)
                    Text("Open vibebuddy on your iPhone and pair it with your Mac. Sessions and weekly quota appear here.")
                        .font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .navigationTitle("vibebuddy")
        }
    }
}

/// Which link is down, when one is. This leads the page, because every number
/// below it is a memory rather than a reading — and because the three failures
/// ask for three different things from the person wearing it.
struct WatchConnectionBanner: View {
    let connection: WatchConnection

    var body: some View {
        if let title = connection.bannerTitle {
            HStack(spacing: 5) {
                Image(systemName: connection.symbolName)
                    .font(.system(size: 10))
                Text(title)
                    .font(CompanionType.font(10))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(CompanionPalette.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .companionCard()
            .accessibilityElement(children: .combine)
        }
    }
}

/// One line of honesty at the bottom of every page: how current this is, and
/// whether any of it is real.
struct WatchFooter: View {
    let state: WatchDashboardState
    let connection: WatchConnection
    let now: Date

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: connection.symbolName)
                    .font(.system(size: 9))
                Text(relayText)
                    .font(CompanionType.font(10))
                    .monospacedDigit()
            }
            .foregroundStyle(CompanionPalette.ink2)

            if state.isDemo {
                Text("Sample data")
                    .font(CompanionType.font(10))
                    .foregroundStyle(CompanionPalette.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .accessibilityElement(children: .combine)
        .padding(.top, 2)
    }

    /// How old this is, always — and the word "Stale" once it is old enough that
    /// the age alone could still be read as a live reading. The banner above says
    /// *why* it is old; repeating that here would spend a line of a 40mm screen
    /// saying nothing new.
    private var relayText: String {
        let age = WatchFormat.updated(state.age(now: now))
        switch connection {
        case .noData: return String(localized: "No data")
        case .live, .macDisconnected: return age
        case .phoneDisconnected, .watchUnreachable: return String(localized: "Stale · \(age)")
        }
    }
}
