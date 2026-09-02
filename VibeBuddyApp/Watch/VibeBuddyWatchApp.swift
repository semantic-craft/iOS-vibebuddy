import SwiftUI
import VibeBuddyKit

@main
struct VibeBuddyWatchApp: App {
    private let launch = WatchLaunch()

    var body: some Scene {
        WindowGroup {
            WatchRootView(launch: launch)
        }
    }
}

/// The two pages of the companion. The urgent alert is not a page: it takes
/// over the home screen, so a blocked session cannot be swiped past by accident.
enum WatchPage: String, Hashable {
    case home
    case quota
}

/// Everything this build knows at launch.
///
/// There is no live relay yet — the iPhone → Watch transport is a later slice —
/// so the companion either runs a deterministic Demo Mode scenario or honestly
/// says it has no data. The clock is captured once, so a screenshot of a given
/// scenario is reproducible.
struct WatchLaunch {
    let state: WatchDashboardState
    let now: Date
    let initialPage: WatchPage

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         now: Date = Date()) {
        self.now = now
        if environment["VIBEBUDDY_DEMO"] == "1" {
            let scenario = environment["VIBEBUDDY_WATCH_SCENARIO"]
                .flatMap(WatchDemoScenario.init(rawValue:)) ?? .normal
            state = scenario.state(now: now)
        } else {
            state = .noData(observedAt: now)
        }
        initialPage = environment["VIBEBUDDY_WATCH_PAGE"]
            .flatMap(WatchPage.init(rawValue:)) ?? .home
    }
}
