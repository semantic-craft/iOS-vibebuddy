import Foundation
import VibeBuddyKit

/// One explicit Mac confirmation, retained across view changes but never queued
/// on disk. Horizon and exact-round reads are independent effects: a snapshot
/// that hides the recap cannot retire a failed completion write.
public struct MacRecapConfirmation: Sendable {
    public struct Batch: Equatable, Sendable {
        public let sourceID: String
        public let horizon: Date
        public let completions: [CompletionReadRequest]
    }

    public private(set) var batch: Batch?
    public private(set) var isRunning = false
    public private(set) var sourceChanged = false
    public private(set) var horizonAccepted = false
    public private(set) var outcomes: [CompletionReadRequest: CompletionReadOutcome] = [:]
    public private(set) var attemptID: UUID?

    public init() {}

    public var pendingCompletions: [CompletionReadRequest] {
        batch?.completions.filter { request in
            switch outcomes[request] {
            case .accepted?, .alreadyAcknowledged?, .staleCompletion?, .unavailable?: false
            default: true
            }
        } ?? []
    }
    public var isComplete: Bool { batch != nil && horizonAccepted && pendingCompletions.isEmpty && !sourceChanged }
    public var canRetry: Bool { batch != nil && !isRunning && !isComplete && !sourceChanged }
    public var skippedCount: Int { outcomes.values.filter { $0 == .staleCompletion || $0 == .unavailable }.count }
    public var resolvedCount: Int { (batch?.completions.count ?? 0) - pendingCompletions.count }

    /// Returns false for repeated taps and while an earlier batch needs retry.
    /// The caller supplies the recap actually rendered by the button.
    @discardableResult
    public mutating func begin(recap: Recap, sourceID: String?, available: Bool) -> Bool {
        guard available, !isRunning, !canRetry, let sourceID, !sourceID.isEmpty,
              let horizon = recap.entries.map(\.endedAt).max() else { return false }
        var seen: Set<CompletionReadRequest> = []
        let requests = recap.entries.compactMap { entry -> CompletionReadRequest? in
            guard entry.kind == .completed, !entry.isRead,
                  let completionID = entry.completionID, !completionID.isEmpty else { return nil }
            let request = CompletionReadRequest(sourceID: sourceID, sessionID: entry.sessionID, completionID: completionID)
            return seen.insert(request).inserted ? request : nil
        }
        let next = Batch(sourceID: sourceID, horizon: horizon, completions: requests)
        guard next != batch else { return false }
        self = Self()
        batch = next
        startAttempt()
        return true
    }

    @discardableResult
    public mutating func retry(sourceID: String?, available: Bool) -> Bool {
        observeSource(sourceID)
        guard available, canRetry, sourceID == batch?.sourceID else { return false }
        startAttempt()
        return true
    }

    private mutating func startAttempt() {
        isRunning = true
        attemptID = UUID()
    }

    /// Missing authority is temporary; a known different source invalidates the
    /// entire batch. Nothing here examines recap.horizon or visible entries.
    public mutating func observeSource(_ sourceID: String?) {
        guard let sourceID, let batch, sourceID != batch.sourceID else { return }
        sourceChanged = true
        isRunning = false
    }

    public mutating func receiveHorizon(_ outcome: RecapReadOutcome, attemptID: UUID) {
        guard self.attemptID == attemptID, isRunning, !sourceChanged else { return }
        switch outcome {
        case .accepted: horizonAccepted = true
        case .sourceMismatch: sourceChanged = true; isRunning = false
        case .failed: break
        }
    }

    public mutating func receiveCompletion(_ outcome: CompletionReadOutcome, request: CompletionReadRequest, attemptID: UUID) {
        guard self.attemptID == attemptID, isRunning, !sourceChanged,
              batch?.completions.contains(request) == true else { return }
        outcomes[request] = outcome
        if outcome == .sourceMismatch { sourceChanged = true; isRunning = false }
    }

    public mutating func finish(attemptID: UUID) {
        guard self.attemptID == attemptID else { return }
        isRunning = false
    }
}
