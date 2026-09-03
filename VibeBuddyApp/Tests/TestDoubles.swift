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
    func notify(_ alert: SoundAlert) {}
    func confirmPairing() {}
}

struct NullDecisionClient: DecisionClient {
    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {}
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
}

/// A Mac that can be told to refuse, so the Watch path can be asked what it says
/// when a decision does not land.
actor UnreachableDecisionClient: DecisionClient {
    private(set) var attempts = 0

    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {}
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool {
        attempts += 1
        return false
    }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
}
