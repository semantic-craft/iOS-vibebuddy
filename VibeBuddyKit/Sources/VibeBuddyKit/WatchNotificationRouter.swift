import Foundation

/// Retains a notification target until the main Watch window is active.
/// Receiving a notification or constructing a store does not make a window
/// ready to present a sheet. Only the window scene can grant that readiness.
@MainActor
public final class WatchNotificationRouter {
    public static let shared = WatchNotificationRouter()

    private var handler: ((String) -> Void)?
    private var pending: String?
    private var windowActive = false

    public init() {}

    public func open(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        pending = sessionID
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

    public func attach(_ handler: @escaping (String) -> Void) {
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
