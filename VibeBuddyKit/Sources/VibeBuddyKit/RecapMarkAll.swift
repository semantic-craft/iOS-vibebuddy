import Foundation

// MARK: - Mark all: the recap's one action, from the wrist to the Mac

/// What the Watch asks the iPhone to do when Mark all is tapped: move the
/// Mac's recap horizon to the newest round the recap showed, then read each
/// completed round it showed, one exact-round acknowledgement at a time. The
/// wrist names the rounds; it never decides they are read.
public struct WatchRecapReadRequest: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watch.recapRead"
    public let attemptID: String
    public let sourceID: String
    public let pairingEpoch: String
    /// The newest entry's `endedAt`, not the moment of the tap.
    public let horizon: Date
    public let completions: [WatchTaskLink]
    public init(attemptID: String, sourceID: String, pairingEpoch: String, horizon: Date, completions: [WatchTaskLink]) {
        self.attemptID = attemptID
        self.sourceID = sourceID
        self.pairingEpoch = pairingEpoch
        self.horizon = horizon
        self.completions = completions
    }

    public var recapRead: RecapReadRequest { RecapReadRequest(sourceID: sourceID, horizon: horizon) }
}

public struct WatchRecapReadResult: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watch.recapResult"
    public let attemptID: String
    public let outcome: RecapReadOutcome
    public init(attemptID: String, outcome: RecapReadOutcome) {
        self.attemptID = attemptID
        self.outcome = outcome
    }
}

/// Persisted on the Watch: the one Mark all that has not yet been seen to
/// land. Like `WatchCompletionQueue`, the authority snapshot — never the radio
/// reply — is what changes the visible recap: a receipt only stops retries.
/// Tapping Mark all again while one is queued does not make a second one; a
/// later recap (newer rounds) replaces it with a request that covers both.
public struct WatchRecapQueue: Codable, Equatable, Sendable {
    /// Waiting to be delivered, or delivered without a definitive receipt.
    public private(set) var pending: WatchRecapReadRequest?
    /// The Mac took it; the recap still shows until a snapshot moves the horizon.
    public private(set) var confirmed: WatchRecapReadRequest?
    /// How many deliveries came back `failed`; the wrist's retry backoff and
    /// its status line read it.
    public private(set) var failures = 0

    public init() {}

    /// Whether this recap is the one a queued Mark all covers.
    public func covers(_ recap: Recap, state: WatchDashboardState) -> Bool {
        guard let request = pending ?? confirmed, let newest = recap.entries.first else { return false }
        return request.sourceID == state.sourceID && request.pairingEpoch == state.pairingEpoch
            && request.horizon >= newest.endedAt
    }

    public var isEmpty: Bool { pending == nil && confirmed == nil }

    /// Mark all on this recap. Nil when the state cannot name a Mac and a
    /// pairing, when the recap is empty, or when an equal-or-later Mark all is
    /// already queued — the second tap is the same intent, not a second send.
    @discardableResult
    public mutating func markAll(_ recap: Recap, state: WatchDashboardState, attemptID: String) -> WatchRecapReadRequest? {
        guard let source = state.sourceID, !source.isEmpty,
              let epoch = state.pairingEpoch, !epoch.isEmpty,
              let newest = recap.entries.first else { return nil }
        if let existing = pending ?? confirmed, existing.sourceID == source, existing.pairingEpoch == epoch,
           existing.horizon >= newest.endedAt { return nil }
        var links = recap.entries.compactMap { entry -> WatchTaskLink? in
            guard entry.kind == .completed, let completionID = entry.completionID, !entry.isRead else { return nil }
            return WatchTaskLink(sourceID: source, pairingEpoch: epoch, sessionID: entry.sessionID, completionID: completionID)
        }
        // A newer recap supersedes a queued request; rounds it named and this
        // recap no longer shows are still read.
        if let existing = pending, existing.sourceID == source, existing.pairingEpoch == epoch {
            for link in existing.completions where !links.contains(link) { links.append(link) }
        }
        let request = WatchRecapReadRequest(attemptID: attemptID, sourceID: source, pairingEpoch: epoch,
                                            horizon: newest.endedAt, completions: links)
        pending = request
        confirmed = nil
        failures = 0
        return request
    }

    /// The phone's receipt. Only a definitive one changes anything here: the
    /// Mac took it (stop retrying, keep it until a snapshot agrees), or the
    /// request named another Mac (drop it). A failed delivery keeps the exact
    /// record for the next try.
    public mutating func received(_ outcome: RecapReadOutcome, attemptID: String) {
        guard let request = pending, request.attemptID == attemptID else { return }
        switch outcome {
        case .accepted:
            pending = nil
            confirmed = request
            failures = 0
        case .sourceMismatch:
            pending = nil
            failures = 0
        case .failed:
            failures = min(failures + 1, 6)
        }
    }

    /// The authority spoke. A new pairing or another Mac invalidates the
    /// request; a live snapshot whose horizon has reached the request's retires
    /// it — that is the moment the recap it covered is gone from every surface.
    public mutating func reconcile(with state: WatchDashboardState) {
        func stale(_ request: WatchRecapReadRequest) -> Bool {
            if let epoch = state.pairingEpoch, request.pairingEpoch != epoch { return true }
            if let source = state.sourceID, state.relay == .live, request.sourceID != source { return true }
            return false
        }
        if let request = pending, stale(request) { pending = nil; failures = 0 }
        if let request = confirmed, stale(request) { confirmed = nil }
        guard state.relay == .live, let horizon = state.recap?.horizon else { return }
        if let request = pending, request.sourceID == state.sourceID, horizon >= request.horizon {
            pending = nil
            failures = 0
        }
        if let request = confirmed, request.sourceID == state.sourceID, horizon >= request.horizon {
            confirmed = nil
        }
    }
}

extension WatchDashboardState {
    /// Demo Mode only: what a later Mac snapshot would say once Mark all
    /// landed. The horizon reaches the newest round and the recap empties; the
    /// completed rounds it covered are no longer unread. Sample data then
    /// travels the same path as real data — the row goes away because the
    /// world changed, not because a button was tapped.
    public func resolvingRecap() -> WatchDashboardState {
        guard let recap, let newest = recap.entries.first else { return self }
        var resolved = self
        resolved.recap = Recap(horizon: newest.endedAt, entries: [])
        let read = Set(recap.entries.filter { $0.kind == .completed && !$0.isRead }.map(\.sessionID))
        resolved.presentation.completeUnread = max(0, presentation.completeUnread - read.count)
        resolved.presentation.idle += read.count
        for index in resolved.followedTasks.indices where read.contains(resolved.followedTasks[index].sessionID)
            && resolved.followedTasks[index].presentation == .completeUnread {
            resolved.followedTasks[index].presentation = .idle
        }
        resolved.results = resolved.results?.filter { !read.contains($0.sessionID) || $0.presentation != .completeUnread }
        return resolved
    }
}
