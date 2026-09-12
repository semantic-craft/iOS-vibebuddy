import Foundation
import VibeBuddyKit

/// Cursor's `AskQuestion` tool input — the tool Cursor's agent calls when it
/// wants the person to choose — and the reply a `preToolUse` hook answers it
/// with.
///
/// Input, as written into Cursor's own agent transcripts on 3.20:
/// `{"title": "…", "questions": [{"id": "…", "prompt": "…",
/// "options": [{"id": "…", "label": "…"}]}]}`. Cursor's key is `prompt` where
/// Claude's is `question`, its options carry `id` + `label` with no description,
/// and the whole call has a `title` that names the decision.
///
/// Unlike Claude's `AskUserQuestion`, there is no contract for handing an answer
/// *back* as the tool's result: `preToolUse` can return `permission`,
/// `user_message`, `agent_message` and `updated_input`, and `updated_input` only
/// rewrites the call. So an answer from the phone is delivered the one way Cursor
/// documents — the question is denied, and the person's choice rides to the model
/// in `agent_message`. The model reads the answer and carries on without asking.
public enum CursorAskQuestionInput {

    public static func pendingQuestion(from input: [String: Any], id: String) -> PendingQuestion? {
        guard let raw = input["questions"] as? [[String: Any]] else { return nil }
        let items: [QuestionItem] = raw.enumerated().compactMap { index, q in
            guard let text = nonEmpty(q["prompt"] as? String) ?? nonEmpty(q["question"] as? String)
            else { return nil }
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o -> QuestionOption? in
                guard let label = nonEmpty(o["label"] as? String) ?? nonEmpty(o["id"] as? String)
                else { return nil }
                let value = nonEmpty(o["label"] as? String) ?? label
                return QuestionOption(id: nonEmpty(o["id"] as? String) ?? label,
                                      label: label, value: value,
                                      description: nonEmpty(o["description"] as? String))
            }
            return QuestionItem(id: nonEmpty(q["id"] as? String) ?? "q\(index + 1)",
                                header: nonEmpty(input["title"] as? String),
                                text: text, options: options,
                                // `allowMultiple` is the ACP spelling (cursor/ask_question).
                                multiSelect: (q["multiSelect"] as? Bool)
                                    ?? (q["multiple"] as? Bool)
                                    ?? (q["allowMultiple"] as? Bool) ?? false,
                                allowsOther: true)
        }
        guard let first = items.first else { return nil }
        return PendingQuestion(id: id, prompt: first.text, options: first.options,
                               questions: items, isBlocking: true)
    }

    /// What the model is told. One line per answered question so a multi-question
    /// call reads unambiguously, and the vibebuddy attribution is explicit so the
    /// model does not mistake it for its own inference.
    public static func agentMessage(question: PendingQuestion, answers: QuestionAnswers) -> String? {
        var lines: [String] = []
        for item in question.items {
            guard let values = answers[item.id]?.filter({ !$0.isEmpty }), !values.isEmpty else { continue }
            lines.append("- \(item.text) → \(values.joined(separator: ", "))")
        }
        guard !lines.isEmpty else { return nil }
        return (["The user answered this question from vibebuddy on their phone:"] + lines
            + ["Continue with those answers; do not ask again."]).joined(separator: "\n")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
