import Foundation

public struct WatchRefreshRequest: Codable, Sendable, Equatable {
    public static let messageKey = "vibebuddy.watch.refresh"
    public let id: UUID
    public let sourceID: String
    public let pairingEpoch: String
    public init(id: UUID = UUID(), sourceID: String, pairingEpoch: String) {
        self.id = id; self.sourceID = sourceID; self.pairingEpoch = pairingEpoch
    }
    public func accepts(_ state: WatchDashboardState) -> Bool {
        !sourceID.isEmpty && !pairingEpoch.isEmpty && state.sourceID == sourceID && state.pairingEpoch == pairingEpoch
    }
}
public struct WatchRefreshReply: Codable, Sendable {
    public static let messageKey = "vibebuddy.watch.refreshReply"
    public let id: UUID
    public let state: WatchDashboardState?
    public init(id: UUID, state: WatchDashboardState?) { self.id = id; self.state = state }
    public func snapshot(for request: WatchRefreshRequest) -> WatchDashboardState? {
        guard id == request.id, let state, request.accepts(state) else { return nil }
        return state
    }
}
