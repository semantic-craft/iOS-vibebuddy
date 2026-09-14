import Foundation

/// Serial, bounded speech work. Each operation revalidates its source before playing.
@MainActor
public final class CompletionSpeechQueue {
    public var onBusyChanged: @MainActor (Bool) -> Void = { _ in }
    public var onEntriesChanged: @MainActor () -> Void = {}
    public private(set) var currentID: String?
    public var pendingIDs: [String] { pending.map(\.id) }
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

    public func enqueue(id: String, priority: Bool = false, allowRepeat: Bool = false,
                        operation: @escaping @MainActor () async -> Void) {
        defer { onEntriesChanged() }
        guard currentID != id, !pending.contains(where: { $0.id == id }) else { return }
        guard allowRepeat || !recentIDs.contains(id) else { return }
        recentIDs.removeAll { $0 == id }
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

    /// An explicit pending read replaces its not-yet-spoken batch with the
    /// current ordered scope. The active operation is never interrupted.
    public func retainPending(ids: Set<String>) {
        pending.removeAll { !ids.contains($0.id) }
        onEntriesChanged()
        if task == nil { onBusyChanged(!pending.isEmpty) }
    }

    public func orderPending(ids: [String]) {
        let rank = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        pending = pending.enumerated().sorted {
            let left = rank[$0.element.id] ?? Int.max
            let right = rank[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        onEntriesChanged()
    }

    public func pause() { isPaused = true }
    public func resume() { isPaused = false; startNext() }

    /// The playback owner stops its player too. Pending entries remain in order.
    public func skip() {
        generation = UUID()
        task?.cancel(); task = nil
        currentID = nil
        startNext()
        onEntriesChanged()
    }

    private func startNext() {
        guard task == nil else { return }
        guard !isPaused, !pending.isEmpty else {
            onBusyChanged(!pending.isEmpty)
            return
        }
        let entry = pending.removeFirst()
        currentID = entry.id
        onEntriesChanged()
        let current = generation
        onBusyChanged(true)
        task = Task { [weak self] in
            await entry.operation()
            guard let self, self.generation == current else { return }
            self.task = nil
            self.currentID = nil
            self.startNext()
            self.onEntriesChanged()
        }
    }

    public func cancel() {
        generation = UUID()
        pending.removeAll()
        task?.cancel(); task = nil
        currentID = nil
        onBusyChanged(false)
        onEntriesChanged()
    }
}
