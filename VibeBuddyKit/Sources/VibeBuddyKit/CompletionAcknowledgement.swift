import Foundation

/// Exact result the person read. A session ID alone never identifies a result.
public struct CompletionReadRequest: Codable, Equatable, Hashable, Sendable {
    public let sourceID: String
    public let sessionID: String
    public let completionID: String
    public init(sourceID: String, sessionID: String, completionID: String) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.completionID = completionID
    }
}

public enum CompletionReadOutcome: String, Codable, Sendable {
    case accepted, alreadyAcknowledged, staleCompletion, sourceMismatch, unavailable, failed
}

public struct CompletionReadResponse: Codable, Sendable {
    public let outcome: CompletionReadOutcome
    public init(outcome: CompletionReadOutcome) { self.outcome = outcome }
}

/// A widget click is an immutable reference to its rendered task and round.
public struct WatchTaskLink: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let sourceID: String
    public let pairingEpoch: String
    public let sessionID: String
    public let completionID: String?
    public var id: String { url.absoluteString }
    public init(sourceID: String, pairingEpoch: String, sessionID: String, completionID: String?) {
        self.sourceID = sourceID; self.pairingEpoch = pairingEpoch
        self.sessionID = sessionID; self.completionID = completionID
    }
    public var url: URL {
        var c = URLComponents()
        c.scheme = "vibebuddy"; c.host = "watch-task"
        c.queryItems = [URLQueryItem(name: "source", value: sourceID),
                       URLQueryItem(name: "epoch", value: pairingEpoch),
                       URLQueryItem(name: "session", value: sessionID)]
        if let completionID { c.queryItems?.append(URLQueryItem(name: "completion", value: completionID)) }
        return c.url!
    }
    public init?(url: URL) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme == "vibebuddy", c.host == "watch-task" else { return nil }
        let items = c.queryItems ?? []
        func value(_ name: String) -> String? {
            let values = items.filter { $0.name == name }
            guard values.count == 1, let value = values.first?.value, !value.isEmpty else { return nil }
            return value
        }
        guard let source = value("source"), let epoch = value("epoch"), let session = value("session") else { return nil }
        self.init(sourceID: source, pairingEpoch: epoch, sessionID: session, completionID: value("completion"))
    }
    public var readRequest: CompletionReadRequest? {
        completionID.map { CompletionReadRequest(sourceID: sourceID, sessionID: sessionID, completionID: $0) }
    }
    public func task(in state: WatchDashboardState?) -> WatchFollowedTask? {
        guard let state, sourceID == state.sourceID, pairingEpoch == state.pairingEpoch else { return nil }
        return state.followedTasks.first { $0.sessionID == sessionID }
    }
}

public struct WatchCompletionRequest: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watch.completionRead"
    public let attemptID: String
    public let link: WatchTaskLink
    public init(attemptID: String, link: WatchTaskLink) { self.attemptID = attemptID; self.link = link }
}
public struct WatchCompletionResult: Codable, Sendable {
    public static let messageKey = "vibebuddy.watch.completionResult"
    public let attemptID: String
    public let outcome: CompletionReadOutcome
    public init(attemptID: String, outcome: CompletionReadOutcome) { self.attemptID = attemptID; self.outcome = outcome }
}

/// Persisted on the Watch. The authority snapshot, never the radio reply, removes
/// a completion from the face. Failed delivery keeps an exact retryable record.
public struct WatchCompletionQueue: Codable, Equatable, Sendable {
    public private(set) var links: [WatchTaskLink] = []
    public init() {}
    public mutating func viewed(_ link: WatchTaskLink, state: WatchDashboardState?) {
        guard let task = link.task(in: state), task.presentation == .completeUnread,
              let completionID = link.completionID, completionID == task.completionID,
              !links.contains(link) else { return }
        links.append(link)
    }
    public mutating func reconcile(with state: WatchDashboardState) {
        // A new pairing invalidates the old queue even before its first Mac
        // snapshot. A same-epoch temporary no-data cannot acknowledge anything.
        if let epoch = state.pairingEpoch {
            links.removeAll { $0.pairingEpoch != epoch }
        }
        // No-data is not an authoritative deletion or acknowledgement.
        guard state.relay == .live, state.sourceID != nil, state.pairingEpoch != nil else { return }
        links.removeAll { link in
            guard let task = link.task(in: state) else { return true }
            return task.completionID != link.completionID || task.presentation != .completeUnread
        }
    }
}
