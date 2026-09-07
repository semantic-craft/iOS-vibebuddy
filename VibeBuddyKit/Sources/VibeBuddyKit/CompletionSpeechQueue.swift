import Foundation

/// Serial completion work. Each operation owns its validation and playback;
/// cancellation invalidates the entire generation, including queued work.
@MainActor
public final class CompletionSpeechQueue {
    public var onBusyChanged: @MainActor (Bool) -> Void = { _ in }
    private struct Entry {
        let id: String
        let operation: @MainActor () async -> Void
    }
    private var pending: [Entry] = []
    private var recentIDs: [String] = []
    private var liveIDs: Set<String> = []
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init() {}

    public func enqueue(id: String, operation: @escaping @MainActor () async -> Void) {
        guard !recentIDs.contains(id), !liveIDs.contains(id) else { return }
        recentIDs.append(id)
        if recentIDs.count > 128 { recentIDs.removeFirst(recentIDs.count - 128) }
        liveIDs.insert(id)
        pending.append(Entry(id: id, operation: operation))
        guard task == nil else { return }
        let current = generation
        onBusyChanged(true)
        task = Task { [weak self] in
            guard let self else { return }
            while self.generation == current, !Task.isCancelled, !self.pending.isEmpty {
                let entry = self.pending.removeFirst()
                await entry.operation()
                guard self.generation == current else { return }
                self.liveIDs.remove(entry.id)
            }
            guard self.generation == current else { return }
            self.task = nil
            self.onBusyChanged(false)
        }
    }

    public func cancel() {
        generation = UUID()
        pending.removeAll()
        liveIDs.removeAll()
        task?.cancel()
        task = nil
        onBusyChanged(false)
    }
}
