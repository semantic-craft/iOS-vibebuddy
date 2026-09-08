import Foundation
import Combine

/// Owns only explicit Settings tests, never the Buddy call or background summaries.
@MainActor
final class SettingsTestCoordinator: ObservableObject {
    enum Purpose: Sendable { case voice, summary, readAloud }
    enum Phase: Sendable { case unverified, running, succeeded, failed, cancelled }
    struct Output: Sendable, Equatable {
        var message: String
        var text: String? = nil
        var details: [String] = []
    }
    enum Outcome: Sendable, Equatable {
        case success(Output)
        case failure(String)
        case cancelled
    }

    @Published private(set) var purpose: Purpose?
    @Published private(set) var phase: Phase = .unverified
    @Published private(set) var outcome: Outcome?
    /// Remains true until both the cancelled operation and resource cleanup finish.
    @Published private(set) var isBusy = false
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var cleanup: @Sendable () async -> Void = {}

    @discardableResult
    func start(_ purpose: Purpose, timeout: Duration,
               operation: @escaping @Sendable () async -> Outcome,
               cleanup: @escaping @Sendable () async -> Void = {}) -> Bool {
        guard !isBusy else { return false }
        let id = UUID()
        generation = id
        self.purpose = purpose
        self.cleanup = cleanup
        outcome = nil
        phase = .running
        isBusy = true
        worker = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let result = await operation()
            await cleanup()
            guard let self, self.generation == id, !Task.isCancelled else { return }
            self.timer?.cancel()
            self.timer = nil
            self.worker = nil
            self.cleanup = {}
            self.outcome = result
            switch result {
            case .success: self.phase = .succeeded
            case .failure: self.phase = .failed
            case .cancelled: self.phase = .cancelled
            }
            self.isBusy = false
        }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == id else { return }
            self.stop(phase: .failed, outcome: .failure("Test timed out. Check your connection and configuration, then retry manually."))
        }
        return true
    }

    func cancel() { stop(phase: .cancelled) }

    /// Used for edits, navigation and the retained NSWindow's willClose event.
    func invalidate() {
        stop(phase: .unverified)
        purpose = nil
    }

    private func stop(phase: Phase, outcome: Outcome? = nil) {
        generation = UUID()
        self.phase = phase
        self.outcome = outcome
        timer?.cancel()
        timer = nil
        guard isBusy, cleanupTask == nil else { return }
        worker?.cancel()
        let worker = self.worker
        let cleanup = self.cleanup
        cleanupTask = Task { [weak self] in
            await cleanup()
            // Cancellation alone is not proof the underlying request has exited.
            await worker?.value
            guard let self else { return }
            self.worker = nil
            self.cleanup = {}
            self.cleanupTask = nil
            self.isBusy = false
        }
    }
}
