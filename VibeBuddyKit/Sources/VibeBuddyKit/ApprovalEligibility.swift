import Foundation

/// Snapshot-backed capability. Device connectivity and Watch preview limits may
/// further restrict it; execution still rechecks the daemon's current request.
public enum ApprovalEligibility {
    public enum UnavailableReason: String, Equatable, Sendable {
        case notWaiting, invalidIdentity, unsupportedSource, readOnly
    }

    public static func unavailableReason(for session: AgentSession) -> UnavailableReason? {
        guard session.status == .needsResponse, session.waitKind == .permission else { return .notWaiting }
        guard !session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let approval = session.pendingApproval,
              !approval.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .invalidIdentity }
        guard session.agent != .grokBot else { return .unsupportedSource }
        guard approval.isAnswerable else { return .readOnly }
        return nil
    }

    public static func approval(for session: AgentSession) -> PendingApproval? {
        unavailableReason(for: session) == nil ? session.pendingApproval : nil
    }
}

/// One indivisible action target shared by local and pushed Live Activities.
public struct ActivityApprovalTarget: Equatable, Sendable {
    public let approvalID: String
    public let title: String
    public let detail: String

    public static func select(from sessions: [AgentSession]) -> Self? {
        for session in sessions {
            guard let approval = ApprovalEligibility.approval(for: session) else { continue }
            return Self(approvalID: approval.id,
                        title: "\(session.project) wants to \(CompanionCopy.requestVerb(approval))",
                        detail: approval.commandPreview)
        }
        return nil
    }
}
