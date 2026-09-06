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
    /// A decision the Watch asked for. The handler answers with what actually
    /// happened, and the transport hands that straight back to the wrist — the
    /// Watch never assumes a tap landed.
    var onApprovalRequest: ((WatchApprovalRequest) async -> WatchApprovalResult)? { get set }
    var onCompletionRequest: ((WatchCompletionRequest) async -> WatchCompletionResult)? { get set }
    var onWaitReadRequest: ((WatchWaitReadRequest) async -> Bool)? { get set }
    /// Hand over the newest state, replacing any earlier one the Watch has not
    /// picked up yet. Throws when the session cannot take it right now.
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

    /// Who decides a Watch tap. The relay owns the only WatchConnectivity
    /// session on this device, so the door in goes through the same object as
    /// the door out; the deciding itself belongs to the store.
    var onApprovalRequest: ((WatchApprovalRequest) async -> WatchApprovalResult)? {
        get { transport.onApprovalRequest }
        set { transport.onApprovalRequest = newValue }
    }

    var onCompletionRequest: ((WatchCompletionRequest) async -> WatchCompletionResult)? {
        get { transport.onCompletionRequest }
        set { transport.onCompletionRequest = newValue }
    }

    var onWaitReadRequest: ((WatchWaitReadRequest) async -> Bool)? {
        get { transport.onWaitReadRequest }
        set { transport.onWaitReadRequest = newValue }
    }

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
        if pending == nil, let lastDelivered, lastDelivered.isEquivalent(to: state),
           state.observedAt.timeIntervalSince(lastDelivered.observedAt) < 60 {
            return false
        }
        return deliver(state)
    }

    /// The Watch can take a value again. Only the newest one is owed — the
    /// intermediate states it missed are exactly what latest-value delivery is
    /// allowed to drop.
    func flush() {
        guard transport.isAvailable, let newest = pending ?? lastDelivered else { return }
        deliver(newest)
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

/// The real transport: one WatchConnectivity session, one latest-value
/// background transfer. It never sends a message the Watch did not ask to
/// render, and it carries no pairing payload of its own.
///
/// The application context, not `transferUserInfo`. Both are background
/// transfers — the system keeps carrying them after the app is backgrounded,
/// the screen locks and the process is suspended, and the counterpart is handed
/// the payload on its next launch — but only the application context is a
/// *mailbox*: writing it replaces whatever the Watch has not picked up yet.
/// That is exactly the de-duplication a dashboard wants. `transferUserInfo` is
/// a FIFO queue, so the same behaviour needs every superseded transfer
/// cancelled by hand, and its delivery is not observable in the watchOS
/// Simulator at all — measured on 2026-09-03: the phone reports
/// `didFinish error: nil` and the Watch's `didReceiveUserInfo` never fires,
/// while the same payload through the application context arrives every time.
@MainActor
final class WatchConnectivityTransport: NSObject, WatchStateTransport {
    var onReady: (() -> Void)?
    var onApprovalRequest: ((WatchApprovalRequest) async -> WatchApprovalResult)?
    var onCompletionRequest: ((WatchCompletionRequest) async -> WatchCompletionResult)?

    var onWaitReadRequest: ((WatchWaitReadRequest) async -> Bool)?

    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// Activation is the only real precondition: the application context is a
    /// latest-value mailbox, so handing it a value before a Watch is reachable
    /// is exactly how it is meant to be used. `isWatchAppInstalled` is
    /// deliberately not consulted — it stays false in the Simulator when the
    /// Watch app is installed directly, and a queued context costs nothing when
    /// there is no Watch to read it.
    var isAvailable: Bool {
        session?.activationState == .activated
    }

    /// Replace whatever the Watch has not picked up yet. A refused write leaves
    /// the state owed: the relay keeps it and hands it over on the next
    /// readiness change.
    func send(_ payload: Data) throws {
        guard let session else { throw WatchRelayError.unsupported }
        try session.updateApplicationContext([WatchStateInbox.contextKey: payload])
    }

    /// Answer one approval message from the wrist. The reply is sent only after
    /// the decision has actually been attempted, so `accepted` on the Watch
    /// means the Mac took it rather than that the radio worked.
    fileprivate nonisolated func handle(approval payload: Data?,
                                        reply: @escaping @Sendable ([String: Any]) -> Void) {
        // An unreadable payload names no attempt, so there is nothing to answer
        // about. Refuse rather than guess which prompt it meant.
        guard let payload,
              let request = try? JSONDecoder().decode(WatchApprovalRequest.self, from: payload)
        else {
            reply([WatchApprovalResult.messageKey: Data()])
            return
        }
        Task { @MainActor [weak self] in
            let result: WatchApprovalResult
            if let handler = self?.onApprovalRequest {
                result = await handler(request)
            } else {
                result = WatchApprovalResult(attemptId: request.attemptId, outcome: .failed)
            }
            reply([WatchApprovalResult.messageKey: (try? JSONEncoder().encode(result)) ?? Data()])
        }
    }

    fileprivate nonisolated func handle(completion payload: Data,
                                        reply: @escaping @Sendable ([String: Any]) -> Void) {
        guard let request = try? JSONDecoder().decode(WatchCompletionRequest.self, from: payload) else {
            reply([WatchCompletionResult.messageKey: Data()]); return
        }
        Task { @MainActor [weak self] in
            let result = await self?.onCompletionRequest?(request)
                ?? WatchCompletionResult(attemptID: request.attemptID, outcome: .failed)
            reply([WatchCompletionResult.messageKey: (try? JSONEncoder().encode(result)) ?? Data()])
        }
    }

    fileprivate nonisolated func handle(waitRead payload: Data,
                                        reply: @escaping @Sendable ([String: Any]) -> Void) {
        guard let request = try? JSONDecoder().decode(WatchWaitReadRequest.self, from: payload) else {
            reply(["accepted": false]); return
        }
        Task { @MainActor [weak self] in
            let accepted = await self?.onWaitReadRequest?(request) ?? false
            reply(["accepted": accepted])
        }
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

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        // Only the payload crosses the actor boundary: `[String: Any]` is not
        // Sendable, and nothing else in the message is ours.
        let payload = message[WatchApprovalRequest.messageKey] as? Data
        let reply = UncheckedSendable(replyHandler)
        if let wait = message[WatchWaitReadRequest.messageKey] as? Data {
            handle(waitRead: wait) { reply.value($0) }
        } else if let completion = message[WatchCompletionRequest.messageKey] as? Data {
            handle(completion: completion) { reply.value($0) }
        } else {
            handle(approval: payload) { reply.value($0) }
        }
    }
}

/// WatchConnectivity hands back a non-Sendable reply closure that must be called
/// exactly once, from anywhere. Nothing else touches it, so carrying it across
/// the hop is safe.
private struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
