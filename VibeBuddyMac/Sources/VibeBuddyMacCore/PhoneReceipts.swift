import Foundation
import VibeBuddyKit

/// What each phone has said it posted itself, so the Mac's push for the same
/// cue can stand down (ADR-0012).
///
/// The phone posts a cue's local notification from the live stream within
/// milliseconds of the transition and then sends `POST /notified`. The Mac's
/// push for the same cue is held for `grace` while a phone still holds a live
/// stream — the only case in which a receipt can still be on its way — and is
/// dropped the moment the receipt for *that* cue and *that* wait arrives. No
/// receipt, and the push goes out as before: a phone that is suspended, gone,
/// or lost the request is exactly the phone the push exists for. The channel
/// only ever removes a push the phone has already shown; it can never remove
/// the only one.
public actor PhoneReceipts {
    public struct Receipt: Sendable, Equatable {
        public let token: String
        public let identifier: String
        public let since: Date
        public let receivedAt: Date
    }

    /// Two clocks never agree exactly; a wait's start is matched to this.
    static let sinceTolerance: TimeInterval = 1

    private var receipts: [Receipt] = []
    private let grace: Duration
    private let memory: TimeInterval
    private let recorder: (any NotificationDeliveryRecording)?

    /// - Parameters:
    ///   - grace: How long a push waits for the phone's receipt while a stream
    ///     is open. The phone needs well under a second on a LAN; the rest is
    ///     headroom for a busy phone. A push nobody was going to duplicate is
    ///     delayed by at most this.
    ///   - memory: How long a receipt is kept. A decision follows its transition
    ///     within seconds (the menu-bar app polls every two), so anything older
    ///     can only be about a wait that is long over.
    ///   - recorder: Where the phone's own declined posts are logged.
    public init(grace: Duration = .seconds(3), memory: TimeInterval = 600,
                recorder: (any NotificationDeliveryRecording)? = nil) {
        self.grace = grace
        self.memory = memory
        self.recorder = recorder
    }

    /// A phone reported what it did about some cues. Both kinds go into the
    /// delivery log on the `phone` channel: it is where the user looks to see
    /// why a banner did or did not appear, and Q26 wants skipped cues named.
    public func record(_ payload: NotifiedPayload, now: Date = Date()) async {
        prune(now: now)
        for cue in payload.posted {
            receipts.append(Receipt(token: payload.token, identifier: cue.identifier,
                                    since: cue.since, receivedAt: now))
            await recorder?.record(NotificationDeliveryRecord(
                channel: .phone, outcome: .scheduled,
                sessionID: nil, sound: NotificationIdentity.sound(of: cue.identifier)?.rawValue,
                failureReason: nil, timestamp: now))
        }
        for cue in payload.coveredByPush {
            await recorder?.record(NotificationDeliveryRecord(
                channel: .phone, outcome: .skipped,
                sessionID: nil, sound: NotificationIdentity.sound(of: cue.identifier)?.rawValue,
                failureReason: CueSkipReason.pushCovered.rawValue, timestamp: now))
        }
    }

    /// The receipt saying `token` already posted `identifier` for the wait that
    /// began at `since`, or nil when there is none. With `hold` the answer is
    /// awaited for up to `grace`: the phone has a live stream, so a receipt may
    /// still be on its way. Without it the answer is immediate — nobody could
    /// be about to send one.
    public func receipt(for identifier: String, since: Date?, from token: String,
                        hold: Bool, now: Date = Date()) async -> Receipt? {
        guard let since else { return nil }
        if let found = match(identifier: identifier, since: since, token: token, now: now) {
            return found
        }
        guard hold else { return nil }
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if let found = match(identifier: identifier, since: since, token: token, now: Date()) {
                return found
            }
        }
        return nil
    }

    private func match(identifier: String, since: Date, token: String, now: Date) -> Receipt? {
        prune(now: now)
        return receipts.last {
            $0.token == token && $0.identifier == identifier
                && abs($0.since.timeIntervalSince(since)) <= Self.sinceTolerance
        }
    }

    private func prune(now: Date) {
        receipts.removeAll { now.timeIntervalSince($0.receivedAt) > memory }
    }
}
