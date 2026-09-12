import Foundation

/// Agent-reported mode is descriptive metadata, never an approval capability.
public enum PermissionMode: String, Codable, Sendable, CaseIterable {
    case bypass, auto, acceptEdits, plan, `default`, unknown

    public static func reported(_ raw: String?, by agent: AgentKind) -> PermissionMode {
        guard agent == .claudeCode else { return .unknown }
        if raw == "bypassPermissions" { return .bypass }
        return raw.flatMap(Self.init(rawValue:)) ?? .unknown
    }
}

public extension AgentSession {
    var permissionDescription: String {
        if agent == .codex {
            return "Approval: \(approvalPolicyRaw ?? "Unknown") · Sandbox: \(sandboxPolicyRaw ?? "Unknown")"
        }
        let mode = agent == .cursor ? PermissionMode.unknown : (permissionMode ?? .unknown)
        return mode == .unknown ? "Unknown" : mode.rawValue
    }
}
