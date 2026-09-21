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
    /// The Mac says the request is no longer waiting: resolved elsewhere or
    /// expired. Nothing was applied.
    case gone(QueuedSessionAction)
    /// A pass ran and the Mac still could not be reached.
    case stillHeld(QueuedSessionAction, reason: ConnectionFailureReason?)
    /// Too old, too many tries, or a re-pairing: given up, nothing applied.
    case dropped(QueuedSessionAction)
    /// The person withdrew it from the phone.
    case cancelled(QueuedSessionAction)

    var action: QueuedSessionAction {
        switch self {
        case .held(let a, _), .superseded(let a, _), .delivered(let a), .gone(let a),
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

    /// Take a decision the Mac could not be given. Reports the hold, and the
    /// earlier decision it replaced if there was one.
    func hold(_ action: QueuedSessionAction, reason: ConnectionFailureReason?) {
        guard action.isHoldable else { return }
        var held = action
        held.lastReason = reason
        let replaced = queue.hold(held)
        save()
        if let replaced { onEvent?(.superseded(replaced, by: held)) }
        onEvent?(.held(held, reason: reason))
    }

    func cancel(id: String) {
        guard let removed = queue.remove(id: id) else { return }
        save()
        onEvent?(.cancelled(removed))
    }

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

    /// One delivery pass. Reads the Mac's own snapshot first, so a held
    /// decision is judged against the live request the way a fresh tap is,
    /// and never against the phone's memory of it.
    func flush(pairing: PairingPayload, epoch: String, client: DecisionClient, now: Date = Date()) async {
        guard !isFlushing else { return }
        prune(now: now, epoch: epoch)
        guard !queue.isEmpty else { return }
        isFlushing = true
        defer { isFlushing = false }
        guard let snapshot = await client.actionSnapshot(pairing) else {
            let reason = ConnectionDiagnosis.diagnose(endpoint: pairing.endpoint, kind: .unreachable,
                                                      phoneHasTailnet: PhoneNetwork.hasTailnetAddress())
            for item in queue.items {
                queue.noteAttempt(id: item.id, reason: reason)
                onEvent?(.stillHeld(item, reason: reason))
            }
            save()
            prune(now: now, epoch: epoch)
            return
        }
        for item in queue.items where item.pairingEpoch == epoch {
            guard let session = snapshot.sessions.first(where: { $0.id == item.sessionId }) else {
                settle(item, .gone); continue
            }
            let result: PhoneActionResult
            switch item.action {
            case .approval(let id, let choice):
                guard ApprovalEligibility.approval(for: session)?.id == id else { settle(item, .gone); continue }
                result = await client.phoneDecision(pairing, approvalId: id, decision: choice.decision,
                                                    requestID: item.id)
            case .answer(let pendingId, let text):
                guard let question = session.pendingQuestion, question.id == pendingId,
                      question.isAnswerable else { settle(item, .gone); continue }
                result = await client.phoneAnswer(pairing, session: session, text: text, answers: nil,
                                                  requestID: item.id)
            case .answerAll(let pendingId, let answers):
                guard let question = session.pendingQuestion, question.id == pendingId,
                      question.isAnswerable else { settle(item, .gone); continue }
                result = await client.phoneAnswer(pairing, session: session, text: nil, answers: answers,
                                                  requestID: item.id)
            case .stop:
                settle(item, .dropped); continue
            }
            switch result {
            case .received:
                settle(item, .delivered)
            case .expired:
                settle(item, .gone)
            case .failed, .unconfirmed, .sending, .notPaired, .held:
                // A lost receipt is retried under the same id; the Mac's
                // request log answers a repeat without applying it again.
                queue.noteAttempt(id: item.id, reason: nil)
                save()
                if let current = queue.item(id: item.id) {
                    onEvent?(.stillHeld(current, reason: nil))
                }
            }
        }
        prune(now: now, epoch: epoch)
    }

    private func settle(_ item: QueuedSessionAction, _ disposal: QueuedActionDisposal) {
        guard queue.remove(id: item.id) != nil else { return }
        save()
        switch disposal {
        case .delivered: onEvent?(.delivered(item))
        case .gone: onEvent?(.gone(item))
        case .dropped: onEvent?(.dropped(item))
        case .cancelled: onEvent?(.cancelled(item))
        case .superseded: break
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
