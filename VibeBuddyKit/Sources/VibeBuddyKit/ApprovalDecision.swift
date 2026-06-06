import Foundation

/// The choices a user can make on a pending approval, shared by the Mac menu-bar
/// app, the iOS app, and the daemon's `/decision` route (ADR 0010). Raw values are
/// the wire strings — do not rename without updating the daemon.
///
/// - `allow` / `deny`: resolve just this one prompt.
/// - `alwaysAllow`: resolve `.allow` and persist a rule so future *identical* tool
///   uses auto-resolve (vibebuddy's own store, not `~/.claude/settings.json`).
/// - `allowSession`: resolve `.allow` and allow everything else in this session
///   until it ends (in-memory).
public enum ApprovalDecision: String, Codable, Sendable, CaseIterable {
    case allow
    case deny
    case alwaysAllow
    case allowSession

    /// Whether this choice approves (vs denies) the current prompt.
    public var approves: Bool { self != .deny }
}
