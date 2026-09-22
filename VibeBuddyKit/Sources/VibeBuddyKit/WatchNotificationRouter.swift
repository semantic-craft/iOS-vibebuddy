import Foundation

/// Retains a notification route until the main Watch window is active.
/// Receiving a notification or constructing a store does not make a window
/// ready to present a sheet. Only the window scene can grant that readiness.
///
/// One route at a time: a later tap replaces an earlier one that was never
/// delivered, because the person is looking at one thing.
@MainActor
public final class WatchNotificationRouter {
    public static let shared = WatchNotificationRouter()

    private var handler: ((WatchNotificationResponseRoute) -> Void)?
    private var pending: WatchNotificationResponseRoute?
    private var windowActive = false

    public init() {}

    /// The default tap: open this session.
    public func open(sessionID: String) {
        route(.open(sessionID: sessionID))
    }

    /// Any route a notification response resolved to. `ignore` clears nothing
    /// and delivers nothing.
    public func route(_ route: WatchNotificationResponseRoute) {
        guard let sessionID = route.sessionID, !sessionID.isEmpty else { return }
        pending = route
        deliverIfReady()
    }

    /// The iPhone Live Activity uses the shared session URL, not the
    /// source-bound Watch complication URL. Bind it from the relay on opening.
    @discardableResult
    public func openActivityURL(_ url: URL) -> Bool {
        guard let sessionID = VibeBuddyDeepLink.sessionId(from: url) else { return false }
        open(sessionID: sessionID)
        return true
    }

    public func attach(_ handler: @escaping (WatchNotificationResponseRoute) -> Void) {
        self.handler = handler
        deliverIfReady()
    }

    public func setWindowActive(_ active: Bool) {
        windowActive = active
        deliverIfReady()
    }

    private func deliverIfReady() {
        guard windowActive, let handler, let pending else { return }
        self.pending = nil
        handler(pending)
    }
}
