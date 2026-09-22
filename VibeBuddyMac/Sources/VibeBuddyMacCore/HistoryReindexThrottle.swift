import Foundation

/// Holds a history source back from being re-indexed while it keeps changing.
///
/// The FSEvents watcher reports a transcript that an agent is appending to
/// several times a second, and each report used to re-parse the whole file,
/// rewrite its FTS5 rows and save `index.json` (rename + fsync). A path is now
/// indexed at most once per `interval`; a change inside the window stays
/// pending and goes out with the next due pass, so nothing is lost, only
/// deferred. A path never seen before is due at once. Liveness comes from the
/// caller's polling loop, which asks `split` again on every tick.
public struct HistoryReindexThrottle: Sendable {
    public let interval: TimeInterval
    private var indexedAt: [String: Date] = [:]

    public init(interval: TimeInterval = 15) {
        self.interval = interval
    }

    /// Splits `pending` into the paths that may be indexed now and the ones
    /// still inside their window.
    public func split(_ pending: Set<String>, now: Date) -> (due: Set<String>, deferred: Set<String>) {
        var due = Set<String>(), deferred = Set<String>()
        for path in pending {
            if let last = indexedAt[path], now.timeIntervalSince(last) < interval {
                deferred.insert(path)
            } else {
                due.insert(path)
            }
        }
        return (due, deferred)
    }

    public mutating func markIndexed(_ paths: Set<String>, at now: Date) {
        for path in paths { indexedAt[path] = now }
    }

    /// Forget paths no longer pending anywhere, so the table tracks live files.
    public mutating func retain(_ paths: Set<String>, now: Date) {
        indexedAt = indexedAt.filter { paths.contains($0.key) || now.timeIntervalSince($0.value) < interval }
    }
}
