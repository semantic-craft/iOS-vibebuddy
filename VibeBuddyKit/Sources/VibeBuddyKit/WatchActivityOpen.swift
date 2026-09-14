import Foundation

/// Read-only lookup of the specific Live Activity that launched the wrist.
public struct WatchActivityOpenRequest: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watch.activityOpen"
    public let requestID: String
    public let activityID: String
    public let sourceID: String
    public let pairingEpoch: String

    public init(requestID: String = UUID().uuidString, activityID: String,
                sourceID: String, pairingEpoch: String) {
        self.requestID = requestID; self.activityID = activityID
        self.sourceID = sourceID; self.pairingEpoch = pairingEpoch
    }

    public func resolve(matchedActivityID: String?, sessionID: String?,
                        state: WatchDashboardState?) -> WatchActivityOpenReply {
        guard !activityID.isEmpty, matchedActivityID == activityID,
              !sourceID.isEmpty, !pairingEpoch.isEmpty,
              let state, state.sourceID == sourceID, state.pairingEpoch == pairingEpoch,
              let sessionID, let task = state.task(sessionID) else {
            return WatchActivityOpenReply(requestID: requestID, link: nil)
        }
        return WatchActivityOpenReply(requestID: requestID,
            link: WatchTaskLink(sourceID: sourceID, pairingEpoch: pairingEpoch,
                                sessionID: sessionID, completionID: task.completionID))
    }
}

public struct WatchActivityOpenReply: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watch.activityOpenReply"
    public let requestID: String
    public let link: WatchTaskLink?
    public init(requestID: String, link: WatchTaskLink?) {
        self.requestID = requestID; self.link = link
    }
}

extension WatchActivityOpenReply {
    public func validatedLink(for request: WatchActivityOpenRequest,
                              state: WatchDashboardState?) -> WatchTaskLink? {
        guard requestID == request.requestID, let link,
              link.sourceID == request.sourceID, link.pairingEpoch == request.pairingEpoch,
              state?.sourceID == request.sourceID, state?.pairingEpoch == request.pairingEpoch else { return nil }
        return link
    }
}
