import Foundation
import VibeBuddyKit
@testable import VibeBuddyApp

/// Shared stand-ins for the store's collaborators, so a test can name only the
/// one it actually cares about.

struct EmptyStreamer: SnapshotStreaming {
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> {
        AsyncStream { $0.finish() }
    }
}

struct SilentNotifier: AttentionNotifier {
    func requestAuthorization() {}
    func notify(_ alert: SoundAlert) async -> Bool { true }
    func withdraw(_ identifiers: [String]) {}
    func confirmPairing() {}
}

/// Remembers what the phone told the user, so a test can assert that the wrist
/// would have been shown it exactly once and that it was taken back on time.
final class RecordingNotifier: AttentionNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var _posted: [String] = []
    private var _withdrawn: [String] = []

    var posted: [String] { lock.withLock { _posted } }
    var withdrawn: [String] { lock.withLock { _withdrawn } }

    func requestAuthorization() {}
    func notify(_ alert: SoundAlert) async -> Bool {
        lock.withLock { _posted.append(alert.notificationID) }
        return true
    }
    func withdraw(_ identifiers: [String]) { lock.withLock { _withdrawn.append(contentsOf: identifiers) } }
    func confirmPairing() {}
}

/// Plays a fixed list of snapshots and then stays open, so the store never runs
/// its reconnect loop in the middle of an assertion.
struct ScriptedStreamer: SnapshotStreaming {
    let snapshots: [Snapshot]

    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            for snapshot in snapshots { continuation.yield(snapshot) }
        }
    }
}

struct NullDecisionClient: DecisionClient {
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}

/// A Mac that can be told to refuse, so the Watch path can be asked what it says
/// when a decision does not land.
actor UnreachableDecisionClient: DecisionClient {
    private(set) var attempts = 0

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome { .accepted }
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool {
        attempts += 1
        return false
    }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
}
