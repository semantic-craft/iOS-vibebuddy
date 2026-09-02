import Foundation
import VibeBuddyKit
import WatchConnectivity

/// Where a projected Watch state goes.
///
/// This protocol is the test seam. Relay behaviour is asserted on what a fake
/// transport actually received, never on WatchConnectivity delegate call order.
@MainActor
protocol WatchStateTransport: AnyObject {
    /// Whether a Watch running our app can be handed a value at all.
    var isAvailable: Bool { get }
    /// Called when the transport becomes able to deliver after refusing.
    var onReady: (() -> Void)? { get set }
    /// Latest-value delivery. Throws when the session cannot take it right now.
    func send(_ payload: Data) throws
}

/// Hands the newest projected state to the Watch, once.
///
/// The iPhone is the only authenticated client of the Mac, and this is the only
/// door to the wrist: what the Watch knows is exactly what the projection put in
/// `WatchDashboardState`, and nothing else on this device is sent.
@MainActor
final class WatchRelay {
    private let transport: WatchStateTransport

    /// The last value the transport accepted. An equivalent projection is not
    /// re-sent: the Watch derives every age and freshness from its own clock, so
    /// an identical payload a second later would spend radio to change nothing.
    private(set) var lastDelivered: WatchDashboardState?
    /// The newest value the transport could not take, retried when it can.
    private(set) var pending: WatchDashboardState?

    init(transport: WatchStateTransport) {
        self.transport = transport
        transport.onReady = { [weak self] in self?.flush() }
    }

    @discardableResult
    func publish(_ state: WatchDashboardState) -> Bool {
        guard transport.isAvailable else {
            pending = state
            return false
        }
        if pending == nil, let lastDelivered, lastDelivered.isEquivalent(to: state) {
            return false
        }
        return deliver(state)
    }

    /// The Watch can take a value again. Only the newest one is owed — the
    /// intermediate states it missed are exactly what latest-value delivery is
    /// allowed to drop.
    func flush() {
        guard let pending, transport.isAvailable else { return }
        deliver(pending)
    }

    @discardableResult
    private func deliver(_ state: WatchDashboardState) -> Bool {
        guard let payload = WatchStateInbox.encode(state) else { return false }
        do {
            try transport.send(payload)
            lastDelivered = state
            pending = nil
            return true
        } catch {
            pending = state
            return false
        }
    }
}

/// The real transport: one WatchConnectivity session, latest-value application
/// context. It never sends a message the Watch did not ask to render, and it
/// carries no pairing payload of its own.
@MainActor
final class WatchConnectivityTransport: NSObject, WatchStateTransport {
    var onReady: (() -> Void)?

    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Activation is the only real precondition: application context is a
    /// latest-value mailbox, so handing it a value before a Watch is reachable
    /// is exactly how it is meant to be used. `isWatchAppInstalled` is
    /// deliberately not consulted — it stays false in the Simulator when the
    /// Watch app is installed directly, and a queued context costs nothing when
    /// there is no Watch to read it.
    var isAvailable: Bool {
        session?.activationState == .activated
    }

    func send(_ payload: Data) throws {
        guard let session else { throw WatchRelayError.unsupported }
        try session.updateApplicationContext([WatchStateInbox.contextKey: payload])
    }

    /// Activation, pairing, and reachability all arrive off the main actor.
    fileprivate nonisolated func readyChanged() {
        Task { @MainActor [weak self] in
            guard let self, self.isAvailable else { return }
            self.onReady?()
        }
    }
}

enum WatchRelayError: Error {
    case unsupported
}

extension WatchConnectivityTransport: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        readyChanged()
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A Watch was unpaired or swapped. Re-activate so the next Watch gets state.
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        readyChanged()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        readyChanged()
    }
}
