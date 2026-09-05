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
    /// The one decision in flight, and everything the wrist may claim about it.
    @Published private(set) var approval = WatchApprovalActionState()
    /// Whether the iPhone is in range right now. It is the only way the Watch
    /// can tell "the phone stopped relaying" from "the phone is gone", and it is
    /// read live rather than relayed — a reachability flag inside a payload
    /// would be describing the moment the payload was sent. A decision is a live
    /// request and needs the phone awake, so it also gates the buttons.
    @Published private(set) var isPhoneReachable = false

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
            isPhoneReachable = scenario.phoneReachable
        } else {
            // A cold launch shows the last state the iPhone managed to deliver.
            // Its age is recomputed from the current clock, never restored as a
            // verdict, so old numbers cannot masquerade as live ones.
            inbox.accept(defaults.data(forKey: Self.storageKey))
            state = inbox.state
            activate()
        }
    }

    /// Whether a decision could be sent at all. Demo Mode resolves its samples
    /// locally, so it needs no phone.
    var canReachPhone: Bool { isDemo || isPhoneReachable }

    /// Ask the iPhone to resolve this approval. A second tap while one is in
    /// flight does nothing — `WatchApprovalActionState` refuses to start a new
    /// attempt — so the decision cannot be submitted twice.
    func submit(_ alert: WatchAlert, _ choice: WatchApprovalChoice) {
        guard canReachPhone,
              let request = approval.begin(alert: alert, choice: choice,
                                           attemptId: UUID().uuidString)
        else { return }

        if isDemo {
            resolveLocally(request)
            return
        }
        guard let session, session.isReachable else {
            approval.fail(attemptId: request.attemptId)
            return
        }
        guard let payload = try? JSONEncoder().encode(request) else {
            approval.fail(attemptId: request.attemptId)
            return
        }
        session.sendMessage(
            [WatchApprovalRequest.messageKey: payload],
            replyHandler: { [weak self] reply in
                // A reply we cannot read tells us nothing landed; treat it as a
                // delivery failure so the tap can be made again.
                let data = reply[WatchApprovalResult.messageKey] as? Data
                let result = data.flatMap { try? JSONDecoder().decode(WatchApprovalResult.self, from: $0) }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let result { self.approval.apply(result) }
                    else { self.approval.fail(attemptId: request.attemptId) }
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.approval.fail(attemptId: request.attemptId)
                }
            })
    }

    /// Demo Mode: the sample approval resolves the way a real one does — the
    /// decision is accepted, and the alert clears only when the next state says
    /// it is gone, not because a button was tapped.
    private func resolveLocally(_ request: WatchApprovalRequest) {
        approval.apply(WatchApprovalResult(attemptId: request.attemptId, outcome: .accepted))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, let current = self.state else { return }
            self.install(current.resolvingApproval(request.approvalId))
        }
    }

    /// Record a new state and let any in-flight decision see it.
    private func install(_ next: WatchDashboardState) {
        state = next
        approval.reconcile(with: next)
    }

    private func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        self.session = session
        session.delegate = self
        session.activate()
    }

    fileprivate func linkChanged(reachable: Bool) {
        isPhoneReachable = reachable
    }

    /// Take a payload from the relay. A payload that cannot be decoded leaves
    /// the last known good state on screen rather than blanking the Watch.
    fileprivate func receive(_ payload: Data?) {
        guard inbox.accept(payload), let accepted = inbox.state else { return }
        install(accepted)
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
        let reachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.linkChanged(reachable: reachable)
            self?.receive(payload)
        }
    }

    /// The iPhone's newest state. It arrives whether the phone wrote it from the
    /// foreground, from behind a locked screen, or just before it was suspended:
    /// the system carries the context on after the sending app exits.
    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = applicationContext[WatchStateInbox.contextKey] as? Data
        Task { @MainActor [weak self] in self?.receive(payload) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor [weak self] in self?.linkChanged(reachable: reachable) }
    }

    // Both are iOS-only (`__WATCHOS_UNAVAILABLE` in the SDK) and never fire on
    // the Watch, but Swift 6.3 insists on witnesses for them all the same.
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
}
