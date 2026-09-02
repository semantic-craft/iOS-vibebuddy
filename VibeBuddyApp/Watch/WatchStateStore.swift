import Foundation
import VibeBuddyKit
import WatchConnectivity

/// Everything the Watch knows, and where it came from.
///
/// The Watch has exactly one source: the paired iPhone, over WatchConnectivity.
/// It opens no LAN socket, discovers no Mac, holds no bearer token, and calls no
/// daemon route — losing the Watch grants nobody access to anything.
///
/// Demo Mode is the one exception, and it is local: a deterministic scenario
/// rendered from a frozen clock so a screenshot of a given launch input always
/// reproduces.
@MainActor
final class WatchStateStore: NSObject, ObservableObject {
    @Published private(set) var state: WatchDashboardState?

    /// Sample data driven entirely by launch inputs; no relay is opened.
    let isDemo: Bool
    /// Demo Mode's frozen clock. Live state ages against the real one.
    let launchedAt: Date
    let initialPage: WatchPage

    private static let storageKey = "vibebuddy.watch.lastState"

    private var inbox = WatchStateInbox()
    private let defaults: UserDefaults
    private var session: WCSession?

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         defaults: UserDefaults = .standard,
         now: Date = Date()) {
        self.defaults = defaults
        launchedAt = now
        isDemo = environment["VIBEBUDDY_DEMO"] == "1"
        initialPage = environment["VIBEBUDDY_WATCH_PAGE"]
            .flatMap(WatchPage.init(rawValue:)) ?? .home
        super.init()

        if isDemo {
            let scenario = environment["VIBEBUDDY_WATCH_SCENARIO"]
                .flatMap(WatchDemoScenario.init(rawValue:)) ?? .normal
            state = scenario.state(now: now)
        } else {
            // A cold launch shows the last state the iPhone managed to deliver.
            // Its age is recomputed from the current clock, never restored as a
            // verdict, so old numbers cannot masquerade as live ones.
            inbox.accept(defaults.data(forKey: Self.storageKey))
            state = inbox.state
            activate()
        }
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    /// Take a payload from the relay. A payload that cannot be decoded leaves
    /// the last known good state on screen rather than blanking the Watch.
    fileprivate func receive(_ payload: Data?) {
        guard inbox.accept(payload), let accepted = inbox.state else { return }
        state = accepted
        defaults.set(WatchStateInbox.encode(accepted), forKey: Self.storageKey)
    }
}

extension WatchStateStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // WatchConnectivity holds the newest context across launches; take it
        // now rather than waiting for the iPhone to have something new to say.
        // Only the payload crosses the actor boundary — `[String: Any]` is not
        // Sendable, and nothing else in the context is ours.
        let payload = session.receivedApplicationContext[WatchStateInbox.contextKey] as? Data
        Task { @MainActor [weak self] in self?.receive(payload) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = applicationContext[WatchStateInbox.contextKey] as? Data
        Task { @MainActor [weak self] in self?.receive(payload) }
    }
}
