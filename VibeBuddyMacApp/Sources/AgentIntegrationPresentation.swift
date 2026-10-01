import Foundation
import SwiftUI
import VibeBuddyKit

/// Settings-only wording. Raw observations and monitoring decisions stay unchanged.
struct AgentPermissionSettingsRow: View {
    let agent: AgentKind
    let session: AgentSession?

    var body: some View {
        SettingsBlockRow {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: agent.displayName).font(SettingsChrome.font(13, .semibold))
                if agent == .codex {
                    Text("Approval: \(approvalTitle)")
                    Text("Sandbox: \(sandboxTitle)")
                } else {
                    Text(verbatim: modeTitle)
                }
                if let session {
                    DisclosureGroup {
                        Text(verbatim: rawValues(session))
                            .font(MacTheme.mono(11.5))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text("\(agent.displayName) reported raw values")
                            .accessibilityIdentifier("agent-permission-raw-\(agent.rawValue)")
                    }
                }
            }
            .font(SettingsChrome.font(12))
            .foregroundStyle(MacTheme.ink2)
        }
    }

    private var modeTitle: String {
        guard agent == .claudeCode else { return String(localized: "Unknown") }
        switch session?.permissionMode ?? .unknown {
        case .bypass: return String(localized: "Permission prompts bypassed")
        case .auto: return String(localized: "Automatic permission decisions")
        case .acceptEdits: return String(localized: "File edits accepted automatically")
        case .plan: return String(localized: "Planning mode")
        case .default: return String(localized: "Default permission prompts")
        case .unknown: return String(localized: "Unknown")
        }
    }

    private var approvalTitle: String {
        switch session?.approvalPolicyRaw {
        case "never": return String(localized: "Never request approval")
        case "on-request": return String(localized: "Request approval when needed")
        case "on-failure": return String(localized: "Request approval after failure")
        case "untrusted": return String(localized: "Request approval for untrusted commands")
        default: return String(localized: "Unknown")
        }
    }

    private var sandboxTitle: String {
        let raw = session?.sandboxPolicyRaw
        let type: String?
        if let data = raw?.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            type = object["type"] as? String
        } else {
            type = raw
        }
        // Name only known types. The raw details remain available; never infer
        // network access or additional writable roots from the type alone.
        switch type {
        case "danger-full-access", "dangerFullAccess": return String(localized: "Full access (no sandbox)")
        case "workspace-write", "workspaceWrite": return String(localized: "Workspace write access")
        case "read-only", "readOnly": return String(localized: "Read-only access")
        case "external-sandbox", "externalSandbox": return String(localized: "Externally managed sandbox")
        default: return String(localized: "Unknown")
        }
    }

    private func rawValues(_ session: AgentSession) -> String {
        let unknown = String(localized: "Unknown")
        if agent == .codex {
            return "approval_policy: \(session.approvalPolicyRaw ?? unknown)\nsandbox_policy: \(session.sandboxPolicyRaw ?? unknown)"
        }
        return "permission_mode: \(session.permissionModeRaw ?? unknown)"
    }
}

enum AgentSourceSettingsPresentation {
    static func title(_ source: ObservationSourceDiagnostic) -> String {
        if source.source == .appserver && source.health == .notInstalled {
            return String(localized: "Control socket unavailable")
        }
        if source.reasonCode == "versionUnverified" {
            return String(localized: "Version \(source.sourceVersion ?? String(localized: "Unknown")) not yet verified")
        }
        // Existing diagnostic text is English in several legacy branches.
        return NSLocalizedString(source.diagnosticTitle, comment: "Agent source diagnostic status")
    }

    static func explanation(_ source: ObservationSourceDiagnostic) -> String {
        if source.source == .appserver && source.health == .notInstalled {
            return String(localized: "No app-server control socket or signal was found. Check the Codex daemon section below. Rollout and Hook are separate sources; this does not establish whether Codex is installed.")
        }
        if source.source == .cloud && source.reasonCode == "optionalSourceNotConfigured" {
            return String(localized: "Optional: add a Cursor API key in Agent integration to follow cloud tasks. Local Cursor monitoring is separate.")
        }
        if source.reasonCode == "configurationIncomplete" {
            let missing = ObservationEventCoverage.allCases.filter { !source.configuredCoverage.contains($0) }
                .map { NSLocalizedString($0.displayName, comment: "Hook event coverage") }.joined(separator: ", ")
            return String(localized: "Missing hook configuration: \(missing). Configured coverage is separate from events received this launch.")
        }
        return NSLocalizedString(source.diagnosticExplanation, comment: "Agent source diagnostic explanation")
    }
}
