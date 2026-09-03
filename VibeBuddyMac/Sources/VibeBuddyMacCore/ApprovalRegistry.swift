import Foundation

/// Holds a blocking `/approval` request until the phone decides (`/decision`) or
/// the timeout fires. Each id is resumed exactly once — whichever of decision or
/// timeout arrives first wins; the other is a no-op.
public actor ApprovalRegistry {
    public enum Outcome: String, Sendable { case allow, deny, pass }

    private var waiters: [String: CheckedContinuation<Outcome, Never>] = [:]
    /// Decisions that arrived before their request started waiting. The pending
    /// card is broadcast an actor hop *before* `/approval` registers its waiter,
    /// so a decision can legitimately land in that window; without this it would
    /// be dropped and the hook would fail open on the timeout instead.
    private var earlyDecisions: [String: Outcome] = [:]

    public init() {}

    public func wait(id: String, timeout: Duration) async -> Outcome {
        if let early = earlyDecisions.removeValue(forKey: id) { return early }
        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            waiters[id] = cont
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resume(id: id, with: .pass)
            }
        }
    }

    public func resolve(id: String, with outcome: Outcome) {
        resume(id: id, with: outcome)
    }

    private func resume(id: String, with outcome: Outcome) {
        guard let cont = waiters.removeValue(forKey: id) else {
            // A timeout for an id nobody is waiting on is spent; a real decision
            // is held briefly for the request that is about to wait on it.
            guard outcome != .pass else { return }
            earlyDecisions[id] = outcome
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.forgetEarlyDecision(id)
            }
            return
        }
        cont.resume(returning: outcome)
    }

    private func forgetEarlyDecision(_ id: String) { earlyDecisions[id] = nil }
}
