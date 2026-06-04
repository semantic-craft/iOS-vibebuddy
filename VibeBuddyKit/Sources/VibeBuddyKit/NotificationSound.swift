import Foundation

/// The built-in sound pack: one short, restrained cue per *state boundary*.
/// Raw values are the bundled file stems. The guiding rule is that only state
/// changes ring — never the process noise in between.
public enum NotificationSound: String, Sendable, CaseIterable, Equatable {
    case pairSuccess   = "pair_success"     // a phone just paired
    case needsAnswer   = "needs_answer"     // the agent asked a question
    case needsApproval = "needs_approval"   // a permission / approval is blocking
    case agentDone     = "agent_done"       // a task finished
    case agentStuck    = "agent_stuck"      // a run failed / got stuck
    case longWaitNudge = "long_wait_nudge"  // a wait has gone unanswered too long

    /// The bundled CAF resource name (`needs_approval.caf`, …).
    public var fileName: String { "\(rawValue).caf" }

    /// In Quiet / Focus mode only the security-decision cue survives; everything
    /// else falls silent (the visual surfaces — banner, Live Activity — remain).
    public var survivesQuietMode: Bool { self == .needsApproval }
}
