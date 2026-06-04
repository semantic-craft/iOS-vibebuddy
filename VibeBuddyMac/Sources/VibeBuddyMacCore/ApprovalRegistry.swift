import Foundation

/// Holds a blocking `/approval` request until the phone decides (`/decision`) or
/// the timeout fires. Each id is resumed exactly once — whichever of decision or
/// timeout arrives first wins; the other is a no-op.
public actor ApprovalRegistry {
    public enum Outcome: String, Sendable { case allow, deny, pass }

    private var waiters: [String: CheckedContinuation<Outcome, Never>] = [:]

    public init() {}

    public func wait(id: String, timeout: Duration) async -> Outcome {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
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
        guard let cont = waiters.removeValue(forKey: id) else { return }
        cont.resume(returning: outcome)
    }
}
