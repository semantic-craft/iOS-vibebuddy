import Foundation

extension AgentSession {
    /// A captured user request or provider title, never inferred from tools.
    public var taskGoal: String {
        if let firstUserPrompt, !firstUserPrompt.isEmpty { return firstUserPrompt }
        if let name, !name.isEmpty { return name }
        return [project, branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Preserve the provider's wording and sections without inventing milestones.
    public var detailProgress: String? {
        if status == .done, let completionID, let notice = completionNotice,
           notice.id.hasSuffix("/" + id + "/" + completionID),
           notice.state == .summary || notice.state == .plain,
           let text = notice.text, !text.isEmpty { return text }
        return status == .done ? completionText : summary
    }

    public var detailProgressSource: String {
        if status == .done, let completionID, let notice = completionNotice,
           notice.id.hasSuffix("/" + id + "/" + completionID),
           notice.state == .summary || notice.state == .plain, notice.text?.isEmpty == false {
            return notice.state == .summary
                ? String(localized: "AI summary · this completion · agent-reported results", bundle: .module)
                : String(localized: "Completion notice · this completion", bundle: .module)
        }
        return String(localized: "Latest observed activity · limited coverage", bundle: .module)
    }
}
