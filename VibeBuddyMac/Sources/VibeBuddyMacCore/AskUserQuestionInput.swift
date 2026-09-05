import Foundation
import VibeBuddyKit

/// Claude Code's `AskUserQuestion` tool input — the same shape whether it
/// arrives on a PreToolUse hook (`tool_input`) or in a transcript's
/// `tool_use` block — and the `updatedInput` a hook answers it with.
///
/// Input: `{questions: [{question, header, options: [{label, description}],
/// multiSelect}]}`. Answer: the original questions plus `answers`, keyed by the
/// question *text*, valued by the chosen label (an array for a multi-select)
/// or the typed reply.
public enum AskUserQuestionInput {
    public static func pendingQuestion(from input: [String: Any], id: String) -> PendingQuestion? {
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        let items: [QuestionItem] = raw.enumerated().compactMap { index, q in
            guard let text = nonEmpty(q["question"] as? String) else { return nil }
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o -> QuestionOption? in
                guard let label = nonEmpty(o["label"] as? String) else { return nil }
                return QuestionOption(id: label, label: label, value: label,
                                      description: nonEmpty(o["description"] as? String))
            }
            return QuestionItem(id: "q\(index + 1)", header: nonEmpty(q["header"] as? String),
                                text: text, options: options,
                                multiSelect: q["multiSelect"] as? Bool ?? false, allowsOther: true)
        }
        guard let first = items.first else { return nil }
        return PendingQuestion(id: id, prompt: first.text, options: first.options,
                               questions: items, isBlocking: true)
    }

    /// The `updatedInput` for the hook reply. Every question keeps its text as
    /// the key; a question left unanswered is omitted, which Claude treats as
    /// unanswered rather than as an error.
    public static func updatedInput(original: [String: Any], question: PendingQuestion,
                                    answers: QuestionAnswers) -> [String: Any] {
        var byText: [String: Any] = [:]
        for item in question.items {
            guard let values = answers[item.id]?.filter({ !$0.isEmpty }), !values.isEmpty else { continue }
            byText[item.text] = item.multiSelect ? values : values[0]
        }
        var updated = original
        updated["answers"] = byText
        return updated
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
