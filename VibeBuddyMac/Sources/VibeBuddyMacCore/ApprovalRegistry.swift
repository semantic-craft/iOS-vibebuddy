import Foundation

/// Holds a blocking approval until a decision or timeout wins. Prepare before
/// publishing its card so a phone can claim it even before `wait` is entered.
public actor ApprovalRegistry {
    public enum Outcome: String, Sendable { case allow, deny, pass }

    private struct Pending {
        var continuation: CheckedContinuation<Outcome, Never>?
        var outcome: Outcome?
        var claimed = false
    }
    private var pending: [String: Pending] = [:]

    public init() {}

    public func prepare(id: String) {
        if pending[id] == nil { pending[id] = Pending() }
    }

    /// Wins against timeout before any permission or interaction side effects.
    public func claim(id: String) -> Bool {
        guard var entry = pending[id], entry.outcome == nil, !entry.claimed else { return false }
        entry.claimed = true
        pending[id] = entry
        return true
    }

    public func wait(id: String, timeout: Duration) async -> Outcome {
        prepare(id: id)
        if let outcome = pending[id]?.outcome {
            pending[id] = nil
            return outcome
        }
        return await withCheckedContinuation { continuation in
            pending[id]?.continuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.resolve(id: id, with: .pass)
            }
        }
    }

    @discardableResult
    public func resolve(id: String, with outcome: Outcome) -> Bool {
        guard var entry = pending[id], entry.outcome == nil,
              !(outcome == .pass && entry.claimed) else { return false }
        if let continuation = entry.continuation {
            pending[id] = nil
            continuation.resume(returning: outcome)
        } else {
            entry.outcome = outcome
            pending[id] = entry
        }
        return true
    }
}
