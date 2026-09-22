import Foundation
import VibeBuddyKit

/// What became of a held decision, for whoever has to tell the person.
enum HeldDeliveryEvent: Equatable {
    /// Just taken into the queue; nothing has reached the Mac.
    case held(QueuedSessionAction, reason: ConnectionFailureReason?)
    /// Replaced by a later decision on the same target.
    case superseded(QueuedSessionAction, by: QueuedSessionAction)
    /// The Mac took it — once, under its request id.
    case delivered(QueuedSessionAction)
    /// The Mac says the request is no longer waiting, and this phone never
    /// managed to send the decision: nothing was applied.
    case gone(QueuedSessionAction)
    /// The request is no longer waiting *after* this phone sent the decision
    /// at least once without a receipt. Whether it was applied is not
    /// something the phone can say; the person has to look.
    case uncertain(QueuedSessionAction)
    /// A pass ran and the Mac still could not be reached.
    case stillHeld(QueuedSessionAction, reason: ConnectionFailureReason?)
    /// Too old, too many tries, or a re-pairing: given up, nothing applied.
    case dropped(QueuedSessionAction)
    /// The person withdrew it from the phone.
    case cancelled(QueuedSessionAction)

    var action: QueuedSessionAction {
        switch self {
        case .held(let a, _), .superseded(let a, _), .delivered(let a), .gone(let a), .uncertain(let a),
             .stillHeld(let a, _), .dropped(let a), .cancelled(let a):
            return a
        }
    }
}

/// The phone's queue of decisions it could not deliver, on disk.
///
/// One instance per process: the wrist's tap, the banner's button and the
/// app's own card all land here when the Mac is unreachable, and the same
/// pass delivers them whether the app came forward, reconnected in the
/// background, or was woken by a push. Every delivery attempt carries the
/// item's id as the Mac's idempotency key, so an attempt whose receipt was
/// lost may be repeated without applying twice (ADR-0032).
@MainActor
final class PendingActionStore: ObservableObject {
    static let shared = PendingActionStore()

    @Published private(set) var queue: SessionActionQueue
    /// Told about every change, on the main actor, after the queue has been
    /// updated and saved. One listener: the dashboard store, which relays to
    /// the wrist, toasts, and hands notifications to the notifier.
    var onEvent: ((HeldDeliveryEvent) -> Void)?
    private(set) var isFlushing = false
    /// A pass was asked for while one was running; the newest such ask runs
    /// once the current pass exits, whichever way it exits.
    private var followUp: (pairing: PairingPayload, epoch: String, client: DecisionClient)?
    /// Items whose POST is out right now. A decision on the same target may
    /// not replace one of these: the earlier POST cannot be recalled, and
    /// delivering the later one on top would be delivering neither.
    private var inFlight: Set<String> = []

    private let url: URL?

    /// `url` nil keeps the queue in memory only (tests).
    init(url: URL? = PendingActionStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SessionActionQueue.self, from: data) {
            queue = saved
        } else {
            queue = SessionActionQueue()
        }
    }

    /// Nil under XCTest: a test host's container outlives its run, and a
    /// decision held by one test must not be delivered by the next.
    static var defaultURL: URL? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("held-decisions.json")
    }

    var isEmpty: Bool { queue.isEmpty }

    /// Whether this item's POST is out right now.
    func isInFlight(_ id: String) -> Bool { inFlight.contains(id) }

    /// Take a decision the Mac could not be given. Returns whether it is now
    /// in the queue; only then is a hold reported. A queue that is full, or a
    /// target whose earlier decision is being delivered this instant, refuses.
    ///
    /// `quietly` takes it without telling anyone yet — for a caller about to
    /// run a delivery pass on its behalf this instant, which would otherwise
    /// announce "on hold" a second before "delivered". The caller says
    /// `announceHeld` if the pass leaves it in the queue.
    @discardableResult
    func hold(_ action: QueuedSessionAction, reason: ConnectionFailureReason?, quietly: Bool = false) -> Bool {
        guard action.isHoldable else { return false }
        if let sameTarget = queue.items.first(where: { $0.targetKey == action.targetKey }),
           sameTarget.id != action.id, inFlight.contains(sameTarget.id) {
            return false
        }
        var held = action
        held.lastReason = reason
        guard case .stored(let replaced) = queue.hold(held) else { return false }
        save()
        if let replaced { onEvent?(.superseded(replaced, by: held)) }
        if !quietly { onEvent?(.held(held, reason: reason)) }
        return true
    }

    /// Report a quietly held decision as held after all: the pass that was
    /// meant to deliver it at once could not, so it is where it was.
    func announceHeld(id: String) {
        guard let item = queue.item(id: id) else { return }
        onEvent?(.held(item, reason: item.lastReason))
    }

    /// Withdraw a held decision. Refused while its POST is out. `quietly`
    /// takes it back without telling anyone — for a card that is about to
    /// send a fresh decision on the same target in its place.
    @discardableResult
    func cancel(id: String, quietly: Bool = false) -> Bool {
        guard !inFlight.contains(id), let removed = queue.remove(id: id) else { return false }
        save()
        if !quietly { onEvent?(.cancelled(removed)) }
        return true
    }

    /// A re-pairing: whatever pass was asked for belongs to the old link.
    func discardFollowUp() { followUp = nil }

    /// Drop what can no longer be delivered, reporting each one.
    @discardableResult
    func prune(now: Date = Date(), epoch: String) -> [QueuedSessionAction] {
        let dropped = queue.prune(now: now, epoch: epoch)
        if !dropped.isEmpty {
            save()
            dropped.forEach { onEvent?(.dropped($0)) }
        }
        return dropped
    }

    /// One delivery pass, then any pass asked for while it ran.
    ///
    /// Each pass reads the Mac's own snapshot first, so a held decision is
    /// judged against the live request the way a fresh tap is, and never
    /// against the phone's memory of it. An attempt is counted only when a
    /// decision left the phone without a receipt; a snapshot that could not
    /// be read, or a POST that never connected, says nothing about it.
    func flush(pairing: PairingPayload, epoch: String, client: DecisionClient, now: Date = Date()) async {
        guard !isFlushing else {
            followUp = (pairing, epoch, client)
            return
        }
        isFlushing = true
        await pass(pairing: pairing, epoch: epoch, client: client, now: now)
        while let next = followUp {
            followUp = nil
            await pass(pairing: next.pairing, epoch: next.epoch, client: next.client, now: Date())
        }
        isFlushing = false
    }

    private func pass(pairing: PairingPayload, epoch: String, client: DecisionClient, now: Date) async {
        prune(now: now, epoch: epoch)
        guard !queue.isEmpty else { return }
        guard let snapshot = await client.actionSnapshot(pairing) else {
            let reason = ConnectionDiagnosis.diagnose(endpoint: pairing.endpoint, kind: .unreachable,
                                                      phoneHasTailnet: PhoneNetwork.hasTailnetAddress())
            for item in queue.items { onEvent?(.stillHeld(item, reason: reason)) }
            return
        }
        // Walk the live queue, not a copy: a decision revised while an
        // earlier POST was out is a new id this pass still has to visit.
        var visited: Set<String> = []
        while let item = queue.items.first(where: { $0.pairingEpoch == epoch && !visited.contains($0.id) }) {
            visited.insert(item.id)
            guard let session = snapshot.sessions.first(where: { $0.id == item.sessionId }) else {
                settleGone(item); continue
            }
            let result: PhoneActionResult
            inFlight.insert(item.id)
            defer { inFlight.remove(item.id) }
            switch item.action {
            case .approval(let id, let choice):
                guard ApprovalEligibility.approval(for: session)?.id == id else { settleGone(item); continue }
                result = await client.phoneDecision(pairing, approvalId: id, decision: choice.decision,
                                                    requestID: item.id)
            case .answer(let pendingId, let text):
                guard let question = session.pendingQuestion, question.id == pendingId,
                      question.isAnswerable else { settleGone(item); continue }
                result = await client.phoneAnswer(pairing, session: session, text: text, answers: nil,
                                                  requestID: item.id)
            case .answerAll(let pendingId, let answers):
                guard let question = session.pendingQuestion, question.id == pendingId,
                      question.isAnswerable else { settleGone(item); continue }
                result = await client.phoneAnswer(pairing, session: session, text: nil, answers: answers,
                                                  requestID: item.id)
            case .stop:
                settle(item, .dropped); continue
            }
            switch result {
            case .received:
                settle(item, .delivered)
            case .expired:
                // The Mac answered and the request is gone. If nothing ever
                // left this phone, nothing was applied; after a receipt was
                // lost, only a look can say.
                settleGone(item)
            case .unconfirmed:
                // It left, and the receipt did not come back. Retried under
                // the same id; the Mac's request log answers a repeat without
                // applying it again. This is the one ending that counts.
                queue.noteAttempt(id: item.id, reason: nil)
                save()
                if let current = queue.item(id: item.id) { onEvent?(.stillHeld(current, reason: nil)) }
            case .failed, .sending, .notPaired, .held:
                // Never connected: the decision is exactly where it was.
                onEvent?(.stillHeld(item, reason: nil))
            }
        }
        prune(now: now, epoch: epoch)
    }

    /// The request this decision was for is no longer waiting. Whether that
    /// means "nothing applied" depends on whether this phone ever posted it.
    private func settleGone(_ item: QueuedSessionAction) {
        settle(item, item.attempts > 0 ? .uncertain : .gone)
    }

    private enum Settlement { case delivered, gone, uncertain, dropped }

    private func settle(_ item: QueuedSessionAction, _ settlement: Settlement) {
        guard queue.remove(id: item.id) != nil else { return }
        save()
        switch settlement {
        case .delivered: onEvent?(.delivered(item))
        case .gone: onEvent?(.gone(item))
        case .uncertain: onEvent?(.uncertain(item))
        case .dropped: onEvent?(.dropped(item))
        }
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(queue).write(to: url, options: .atomic)
        } catch { /* An unsaved queue survives this process; it must not stop the delivery. */ }
    }
}
