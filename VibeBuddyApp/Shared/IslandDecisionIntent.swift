import ActivityKit
import AppIntents
import Foundation
import VibeBuddyKit

/// Approve or deny the leading session's request from the Dynamic Island or
/// the lock screen (island-approve/01). A `LiveActivityIntent` runs inside the
/// app's own process, so it reads the saved pairing the way the app does and
/// posts `/decision` with the same client; the banner is then updated locally
/// so the answer shows before the Mac's next push confirms it.
///
/// Only `allow` / `deny` live here: the wider grants stay in the app, where the
/// full command is readable (ADR-0010).
struct IslandDecisionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer an approval"
    static let isDiscoverable = false

    @Parameter(title: "Approval") var approvalId: String
    @Parameter(title: "Allow") var allow: Bool

    init() {}
    init(approvalId: String, allow: Bool) {
        self.approvalId = approvalId
        self.allow = allow
    }

    func perform() async throws -> some IntentResult {
        let accepted: Bool
        if let pairing = IslandPairing.load() {
            accepted = await HTTPDecisionClient().decide(pairing, approvalId: approvalId,
                                                         decision: allow ? .allow : .deny)
        } else {
            accepted = false
        }
        await IslandActivity.markSent(approvalId: approvalId, outcome: accepted ? (allow ? "allow" : "deny") : "failed")
        return .result()
    }
}

/// The pairing the app saved (`ConnectionStore`), read from the app's own
/// defaults — the intent executes in the app process, so they are the same.
enum IslandPairing {
    static let key = "vibebuddy.pairing"
    static func load() -> PairingPayload? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PairingPayload.self, from: data)
    }
}

/// Flip the banner for the approval just answered.
enum IslandActivity {
    @MainActor
    static func markSent(approvalId: String, outcome: String) async {
        for activity in Activity<VibeBuddyActivityAttributes>.activities
        where activity.content.state.approvalId == approvalId {
            var state = activity.content.state
            state.decisionSent = outcome
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }
}
