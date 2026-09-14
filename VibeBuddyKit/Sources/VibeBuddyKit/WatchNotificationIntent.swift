import Foundation

/// A recent notification tap survives process replacement, but never a new pairing.
public struct WatchNotificationIntent: Codable, Equatable, Sendable {
    public let link: WatchTaskLink
    public let createdAt: Date
    public init(link: WatchTaskLink, createdAt: Date = .now) {
        self.link = link
        self.createdAt = createdAt
    }
    public func target(in state: WatchDashboardState?, now: Date = .now) -> WatchTaskLink? {
        guard now.timeIntervalSince(createdAt) >= 0, now.timeIntervalSince(createdAt) < 300,
              link.sourceID == state?.sourceID, link.pairingEpoch == state?.pairingEpoch else { return nil }
        return link
    }
}
