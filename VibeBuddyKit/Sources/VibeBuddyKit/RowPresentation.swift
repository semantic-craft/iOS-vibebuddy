import Foundation

/// A shared reading order, derived only from observed session and result text.
/// Result wording is the agent's account, not an independent verification.
public struct RowPresentation: Equatable, Sendable {
    public let title: String
    public let activityOrResult: String
    public let progress: String?
    public let unread: Bool
    public let updatedAt: Date
    public let observationWarning: String?
    public let lastObservedAt: Date?

    public init(session: AgentSession) {
        title = session.displayTitle
        unread = session.status == .done && session.hasUnreadCompletion
        updatedAt = session.updatedAt
        if session.status == .done && session.historyOnly != true && !session.isStuck {
            activityOrResult = Self.firstSentence(session.completionSummary)
                ?? Self.firstSentence(session.completionText)
                ?? String(localized: "This turn ended", bundle: .module)
        } else {
            activityOrResult = ToolActivity.label(for: session)
        }
        let latest = Self.firstSentence(session.summary)
        progress = latest == activityOrResult ? nil : latest
        observationWarning = session.observations?.contains(where: { !$0.health.isHealthy }) == true
            ? session.observationDescription : nil
        lastObservedAt = session.lastObservedAt
    }

    /// Bounded readable first sentence; headings alone are not a result.
    public static func firstSentence(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let line = lines.map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") }) else { return nil }
        var sentence = ""
        let characters = Array(line)
        for (index, character) in characters.enumerated() {
            sentence.append(character)
            if "。！？!?".contains(character) { break }
            if character == ".", index + 1 == characters.count || characters[index + 1].isWhitespace { break }
        }
        return String(sentence.prefix(280))
    }
}
