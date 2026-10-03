import Foundation

public extension AgentSession {
    /// Origin is a source fact, never inferred from a title or project.
    var sourceSurfaceLabel: String? { agent.surfaceLabel(agentSource) }
    var agentSourceLabel: String { agent.sessionLabel(agentSource) }
}

public extension AgentKind {
    func surfaceLabel(_ source: String?) -> String? {
        guard self == .antigravity else { return nil }
        switch source {
        case "CLI": return "CLI"
        case "Desktop": return String(localized: "Desktop", bundle: .module)
        case "IDE": return "IDE"
        default: return nil
        }
    }

    func sessionLabel(_ source: String?) -> String {
        guard let surface = surfaceLabel(source) else { return shortName }
        return "\(shortName) · \(surface)"
    }
}
