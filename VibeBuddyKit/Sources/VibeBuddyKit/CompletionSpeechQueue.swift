import Foundation

/// Serial, bounded speech work. Each operation revalidates its source before playing.
@MainActor
public final class CompletionSpeechQueue {
    public var onBusyChanged: @MainActor (Bool) -> Void = { _ in }
    public var onOverflow: @MainActor () -> Void = {}
    public private(set) var isPaused = false
    public var pendingCount: Int { pending.count }
    private struct Entry {
        let id: String
        let order: Int
        let operation: @MainActor () async -> Void
    }
    private var pending: [Entry] = []
    private var serial = 0
    private var recentIDs: [String] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init() {}

    public func enqueue(id: String, priority: Bool = false,
                        operation: @escaping @MainActor () async -> Void) {
        guard !recentIDs.contains(id) else { return }
        recentIDs.append(id)
        if recentIDs.count > 128 { recentIDs.removeFirst(recentIDs.count - 128) }
        // Evict the oldest queued item before inserting the newest event.
        let capacity = task == nil ? 10 : 9
        if pending.count >= capacity, let oldest = pending.indices.min(by: { pending[$0].order < pending[$1].order }) {
            pending.remove(at: oldest); onOverflow()
        }
        serial += 1
        let entry = Entry(id: id, order: serial, operation: operation)
        if priority { pending.insert(entry, at: 0) } else { pending.append(entry) }
        startNext()
    }

    public func pause() { isPaused = true }
    public func resume() { isPaused = false; startNext() }

    /// The playback owner stops its player too. Pending entries remain in order.
    public func skip() {
        generation = UUID()
        task?.cancel(); task = nil
        startNext()
    }

    private func startNext() {
        guard task == nil else { return }
        guard !isPaused, !pending.isEmpty else {
            onBusyChanged(!pending.isEmpty)
            return
        }
        let entry = pending.removeFirst()
        let current = generation
        onBusyChanged(true)
        task = Task { [weak self] in
            await entry.operation()
            guard let self, self.generation == current else { return }
            self.task = nil
            self.startNext()
        }
    }

    public func cancel() {
        generation = UUID()
        pending.removeAll()
        task?.cancel(); task = nil
        onBusyChanged(false)
    }
}
