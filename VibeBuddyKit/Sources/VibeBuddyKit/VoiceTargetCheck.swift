import Foundation

/// Whether the user's own words named the task a voice action targets
/// (ADR-0008, 2026-09-24 amendment; RV-03).
///
/// The model picks the target, and it can pick a different task that is also
/// waiting (Qwen sent `deny_session(orange)` for "reject grape"). This check is
/// independent of the model: a task action is sent only when the text the user
/// was heard saying in the current exchange names the target's project or
/// title. It is a veto, never an authorization — a name in the transcript does
/// not make the app act on its own.
///
/// Matching is lenient about spelling and strict about identity: case, spaces
/// and punctuation are ignored ("vibe buddy" names `vibe-buddy`), and a distinct
/// word of the project name counts when no other task in scope shares it. A
/// name heard only inside a longer in-scope name does not count (`app` is not
/// named by "app-server").
public enum VoiceTargetCheck {
    public enum Verdict: Equatable, Sendable {
        /// The user's words name the target.
        case named
        /// The user's words name another task in scope instead.
        case namedOther(String)
        /// The user's words name no task in scope (or nothing was heard yet).
        case unnamed
    }

    /// `target` is the resolved session; `scope` is every session the call can act on.
    public static func verdict(target: AgentSession, heard: String, scope: [AgentSession]) -> Verdict {
        let spoken = Spoken(heard)
        let others = scope.filter { $0.id != target.id }
        if mentions(target, in: spoken, others: others) { return .named }
        if let other = others.first(where: { other in
            mentions(other, in: spoken, others: scope.filter { $0.id != other.id })
        }) {
            return .namedOther(other.displayTitle)
        }
        return .unnamed
    }

    /// For a caller without a session scope: the model-supplied name itself must be heard.
    public static func verdict(project: String, heard: String) -> Verdict {
        let name = normalize(project)
        return name.count >= 2 && !Spoken(heard).occurrences(of: name).isEmpty ? .named : .unnamed
    }

    static func mentions(_ session: AgentSession, in spoken: Spoken, others: [AgentSession]) -> Bool {
        let otherNames = others.flatMap(names)
        // Spans of longer in-scope names that were heard; a name inside one does not count.
        func free(_ name: String) -> Bool {
            let covered = otherNames.filter { $0.count > name.count && $0.contains(name) }
                .flatMap { spoken.occurrences(of: $0) }
            return spoken.occurrences(of: name).contains { hit in
                !covered.contains { $0.lowerBound <= hit.lowerBound && hit.upperBound <= $0.upperBound }
            }
        }
        if names(session).contains(where: { $0.count >= 2 && free($0) }) { return true }
        // A distinct word of the project name, e.g. "ios" for "ios-vibebuddy".
        let otherWords = Set(others.flatMap { words($0.project) })
        return words(session.project).contains { $0.count >= 3 && !otherWords.contains($0) && free($0) }
    }

    private static func names(_ session: AgentSession) -> [String] {
        [session.project, session.name ?? ""].map(normalize).filter { !$0.isEmpty }
    }

    private static func words(_ project: String) -> [String] {
        let parts = project.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return parts.count > 1 ? parts : []
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Heard text without case, spaces or punctuation, remembering where words
    /// began and ended so a Latin name matches whole words only ("app" is not
    /// heard in "approve"). Next to a non-ASCII letter (Chinese has no spaces)
    /// any position is a boundary.
    struct Spoken {
        let chars: [Character]
        let boundaries: Set<Int>

        init(_ heard: String) {
            var chars: [Character] = []
            var boundaries: Set<Int> = [0]
            for c in heard.lowercased() {
                if c.isLetter || c.isNumber { chars.append(c) } else { boundaries.insert(chars.count) }
            }
            boundaries.insert(chars.count)
            self.chars = chars
            self.boundaries = boundaries
        }

        func occurrences(of name: String) -> [Range<Int>] {
            let needle = Array(name)
            guard !needle.isEmpty, needle.count <= chars.count else { return [] }
            return (0...(chars.count - needle.count)).compactMap { start in
                let end = start + needle.count
                guard Array(chars[start..<end]) == needle, edge(start), edge(end) else { return nil }
                return start..<end
            }
        }

        private func edge(_ i: Int) -> Bool {
            boundaries.contains(i) || !chars[i - 1].isASCII || !chars[i].isASCII
        }
    }
}

public extension VoiceAction {
    /// The target of an action that reaches a coding task (approve, deny,
    /// answer, instruct). Marking a result read changes no task, so it is not
    /// held for the naming check.
    var taskTarget: String? {
        switch self {
        case .approve(let project), .deny(let project), .answer(let project, _), .instruct(let project, _):
            project
        case .markRead, .none:
            nil
        }
    }
}
