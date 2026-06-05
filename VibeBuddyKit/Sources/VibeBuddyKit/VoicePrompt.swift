import Foundation

/// An action the voice companion can take on the user's behalf.
public enum VoiceAction: Equatable, Sendable {
    case approve(project: String)
    case deny(project: String)
    case answer(project: String, text: String)
    case none
}

/// Builds the companion's system prompt from live session state and parses the
/// model's reply into a spoken part + an optional action. Pure & unit-tested.
public enum VoicePrompt {
    /// How the companion is told to act on sessions.
    /// - `directive`: emit a trailing `ACTION:` text line (the turn-based path).
    /// - `tools`: call the provided function tools (the realtime speech path,
    ///   where the model can't speak a separate text directive aloud).
    public enum ActionStyle: Sendable { case directive, tools }

    public static func systemPrompt(sessions: [AgentSession],
                                    language: VoiceLanguage = .english,
                                    actionStyle: ActionStyle = .directive) -> String {
        var lines = [
            "You are VibeBuddy, a concise, warm voice companion for a developer watching AI coding agents.",
            "\(language.replyInstruction) Keep it to one or two short spoken sentences — no markdown, no lists.",
            "Current sessions:",
        ]
        if sessions.isEmpty { lines.append("- (none right now)") }
        for s in sessions {
            let status: String
            switch s.status {
            case .needsResponse: status = s.waitKind == .permission ? "waiting for approval" : "waiting for your answer"
            case .working:       status = s.isStuck ? "stuck" : "working"
            case .done:          status = s.isStuck ? "failed" : "done"
            }
            let summary = s.summary.map { " — \($0)" } ?? ""
            lines.append("- \(s.project) [\(s.agent.shortName)]: \(status)\(summary)")
        }
        lines.append("")
        switch actionStyle {
        case .directive:
            lines.append("If the user asks you to approve, deny, or answer a session, do it: give a short spoken confirmation, then on a FINAL separate line output exactly one directive:")
            lines.append("ACTION: approve <project>   |   ACTION: deny <project>   |   ACTION: answer <project> :: <text>")
            lines.append("Use a project name from the list above. If no action is requested, omit the ACTION line.")
        case .tools:
            lines.append("You can act for the user with the provided tools: approve_session, deny_session, and answer_session. Call one ONLY when the user clearly and explicitly asks for that action on a specific session — never from an ambiguous or passing mention of approval (approving runs real commands). Use a project name from the list above; if unsure which session they mean, ask instead of calling a tool. After the tool result returns, give a short spoken confirmation. If no action is clearly requested, just talk.")
        }
        return lines.joined(separator: "\n")
    }

    /// Split a reply into the spoken text and a parsed action (if any).
    public static func parse(_ reply: String) -> (spoken: String, action: VoiceAction) {
        let lines = reply.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let idx = lines.lastIndex(where: { $0.uppercased().hasPrefix("ACTION:") }) else {
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), .none)
        }
        let spoken = lines[..<idx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let directive = String(lines[idx].dropFirst("ACTION:".count)).trimmingCharacters(in: .whitespaces)
        let action = parseDirective(directive)
        return (spoken.isEmpty ? reply.trimmingCharacters(in: .whitespacesAndNewlines) : spoken, action)
    }

    private static func parseDirective(_ d: String) -> VoiceAction {
        let lower = d.lowercased()
        if lower.hasPrefix("approve ") {
            return .approve(project: String(d.dropFirst(8)).trimmingCharacters(in: .whitespaces))
        }
        if lower.hasPrefix("deny ") {
            return .deny(project: String(d.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        if lower.hasPrefix("answer ") {
            let rest = String(d.dropFirst(7))
            if let sep = rest.range(of: "::") {
                let project = String(rest[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
                let text = String(rest[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !project.isEmpty, !text.isEmpty { return .answer(project: project, text: text) }
            }
        }
        return .none
    }
}
