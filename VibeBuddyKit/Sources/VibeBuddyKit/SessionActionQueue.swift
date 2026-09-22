import Foundation

/// A decision the phone accepted but could not deliver to the Mac yet.
///
/// The phone is the only device that can reach the Mac, and the wrist and the
/// banner both hand their taps to it. When the Mac is unreachable — the
/// tailnet is off, the Mac is asleep — the tap used to be dropped in silence.
/// Now it is *held*: recorded here with the idempotency key the Mac will
/// deduplicate on (`ActionRequestLog`), retried when the link returns, and
/// visible on every surface until it lands or can no longer apply.
///
/// Only approvals and answers are held. A stop is destructive and bound to a
/// turn that will not be there later; it fails at once and says so.
public struct QueuedSessionAction: Codable, Equatable, Sendable, Identifiable {
    /// Where the tap came from, so the report goes back the same way: a
    /// mirrored notification for the wrist and the banner, a toast in the app.
    public enum Origin: String, Codable, Sendable {
        case watch, banner, phone
    }

    /// The idempotency key. It travels as `requestId` on every delivery
    /// attempt, so a retry after a lost receipt cannot apply twice.
    public var id: String
    public var sessionId: String
    public var action: WatchSessionAction
    public var origin: Origin
    /// The pairing this was aimed at. A held decision never crosses a
    /// re-pairing: a new token or a new Mac is a new world.
    public var pairingEpoch: String
    public var queuedAt: Date
    public var attempts: Int
    public var lastReason: ConnectionFailureReason?
    /// Labels for the notification and the Inbox row; never authority.
    public var project: String?
    public var agent: AgentKind?

    public init(id: String, sessionId: String, action: WatchSessionAction, origin: Origin,
                pairingEpoch: String, queuedAt: Date, attempts: Int = 0,
                lastReason: ConnectionFailureReason? = nil,
                project: String? = nil, agent: AgentKind? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.action = action
        self.origin = origin
        self.pairingEpoch = pairingEpoch
        self.queuedAt = queuedAt
        self.attempts = attempts
        self.lastReason = lastReason
        self.project = project
        self.agent = agent
    }

    /// What the action is aimed at. Two actions on one target are one
    /// decision revised, not two decisions.
    public var targetKey: String {
        switch action {
        case .approval(let id, _): return "approval:\(id)"
        case .answer(let pendingId, _), .answerAll(let pendingId, _): return "question:\(sessionId):\(pendingId)"
        case .stop: return "stop:\(sessionId)"
        }
    }

    public var approvalId: String? {
        if case .approval(let id, _) = action { return id }
        return nil
    }

    public var pendingId: String? {
        switch action {
        case .answer(let id, _), .answerAll(let id, _): return id
        case .approval, .stop: return nil
        }
    }

    public var choice: WatchApprovalChoice? {
        if case .approval(_, let choice) = action { return choice }
        return nil
    }

    /// Whether this kind of action may be held at all.
    public var isHoldable: Bool { !action.isDestructive }
}

/// The phone's queue of held decisions, as a value.
public struct SessionActionQueue: Codable, Equatable, Sendable {
    public private(set) var items: [QueuedSessionAction]

    /// How long a decision stays worth delivering. A permission prompt a Cursor
    /// cloud agent held for half an hour was still the same prompt; six hours
    /// covers a night with the tunnel off without keeping decisions for days.
    public static let maxAge: TimeInterval = 6 * 60 * 60
    /// Retries after which the link is declared the problem, not the timing.
    public static let maxAttempts = 12
    /// A person makes a handful of decisions, not a backlog.
    public static let limit = 16

    public init(items: [QueuedSessionAction] = []) {
        self.items = items
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// What `hold` did, so the caller never reports a hold that did not happen.
    public enum HoldResult: Equatable, Sendable {
        /// In the queue, with the earlier decision on the same target it
        /// replaced, if there was one.
        case stored(replaced: QueuedSessionAction?)
        /// Not stored: a destructive action, or the queue is full. Nothing
        /// changed, and the caller must report a failure, not a hold.
        case rejected
    }

    /// Hold an action. A later action on the same target replaces the earlier
    /// one — a Deny after a held Approve is a change of mind, and delivering
    /// both would be delivering neither.
    @discardableResult
    public mutating func hold(_ action: QueuedSessionAction) -> HoldResult {
        guard action.isHoldable else { return .rejected }
        if let existing = items.firstIndex(where: { $0.id == action.id }) {
            items[existing] = action
            return .stored(replaced: nil)
        }
        let sameTarget = items.firstIndex { $0.targetKey == action.targetKey }
        // Full, and nothing of this target's to replace: refuse before
        // touching anything.
        guard sameTarget != nil || items.count < Self.limit else { return .rejected }
        let superseded = sameTarget.map { items.remove(at: $0) }
        items.append(action)
        return .stored(replaced: superseded)
    }

    @discardableResult
    public mutating func remove(id: String) -> QueuedSessionAction? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// One more delivery attempt failed for this reason.
    public mutating func noteAttempt(id: String, reason: ConnectionFailureReason?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].attempts += 1
        items[index].lastReason = reason
    }

    /// Drop what can no longer be delivered, and say what was dropped.
    public mutating func prune(now: Date, epoch: String) -> [QueuedSessionAction] {
        let dropped = items.filter {
            $0.pairingEpoch != epoch
                || now.timeIntervalSince($0.queuedAt) > Self.maxAge
                || $0.attempts >= Self.maxAttempts
        }
        items.removeAll { item in dropped.contains { $0.id == item.id } }
        return dropped
    }

    public func item(id: String) -> QueuedSessionAction? { items.first { $0.id == id } }

    public func held(approvalId: String) -> QueuedSessionAction? {
        items.first { $0.approvalId == approvalId }
    }

    public func held(sessionId: String, pendingId: String) -> QueuedSessionAction? {
        items.first { $0.sessionId == sessionId && $0.pendingId == pendingId }
    }

    /// What the wrist is told about held decisions — enough to say "your
    /// iPhone is holding this", nothing it could act on.
    public func watchProjection(epoch: String) -> [WatchHeldAction] {
        items.filter { $0.pairingEpoch == epoch }.map {
            WatchHeldAction(id: $0.id, sessionId: $0.sessionId, approvalId: $0.approvalId,
                            pendingId: $0.pendingId, choice: $0.choice, heldSince: $0.queuedAt)
        }
    }
}

/// A held decision as the Watch sees it: a label on the card it came from.
public struct WatchHeldAction: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sessionId: String
    public var approvalId: String?
    public var pendingId: String?
    public var choice: WatchApprovalChoice?
    public var heldSince: Date

    public init(id: String, sessionId: String, approvalId: String? = nil, pendingId: String? = nil,
                choice: WatchApprovalChoice? = nil, heldSince: Date) {
        self.id = id
        self.sessionId = sessionId
        self.approvalId = approvalId
        self.pendingId = pendingId
        self.choice = choice
        self.heldSince = heldSince
    }
}
