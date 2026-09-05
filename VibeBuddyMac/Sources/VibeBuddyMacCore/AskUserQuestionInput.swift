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
            // Claude sends `{label, description}`; a transcript written by an
            // older CLI may carry `id` and a distinct `value` — keep both.
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o -> QuestionOption? in
                guard let label = nonEmpty(o["label"] as? String) else { return nil }
                return QuestionOption(id: nonEmpty(o["id"] as? String) ?? label, label: label,
                                      value: nonEmpty(o["value"] as? String) ?? label,
                                      description: nonEmpty(o["description"] as? String))
            }
            return QuestionItem(id: nonEmpty(q["id"] as? String) ?? "q\(index + 1)",
                                header: nonEmpty(q["header"] as? String),
                                text: text, options: options,
                                multiSelect: q["multiSelect"] as? Bool ?? false, allowsOther: true)
        }
        guard let first = items.first else { return nil }
        // A question that names itself keeps that name as the card's id, as
        // the transcript reader always did; otherwise the caller's id.
        let questionID = nonEmpty(raw.first?["id"] as? String) ?? id
        return PendingQuestion(id: questionID, prompt: first.text, options: first.options,
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
