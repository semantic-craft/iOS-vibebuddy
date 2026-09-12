import SwiftUI
import VibeBuddyKit

/// Answering a prompt with several questions from the wrist, one screen each.
///
/// Cursor's `AskQuestion` usually asks two or three things at once, each with
/// its own choices. One string cannot answer that, but one pick per question
/// can, so the card offers a walk: question 1, pick; question 2, pick; then
/// one page that reads the whole set back and sends it once. Leaving the walk
/// anywhere before Send discards every pick — a half-answered prompt is not
/// an answer, and nothing partial is ever kept or sent.
///
/// The control only exists for a prompt the iPhone would actually forward
/// (`WatchAlert.questions`, set by the same `WatchQuestionSet` rule the gate
/// re-runs). The one-question wait keeps its own control, unchanged.
struct WatchQuestionWalkControl: View {
    @ObservedObject var store: WatchStateStore
    let alert: WatchAlert
    let questions: [WatchQuestionItem]
    /// Why nothing can be sent right now, from the card's own link check.
    let blocked: LocalizedStringResource?
    let phase: WatchSessionActionAttempt.Phase?
    @State private var walk: WatchQuestionWalkDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // No button while nothing could travel; the card above has already
            // named the broken link.
            if blocked == nil {
                Button {
                    walk = WatchQuestionWalkDraft(alert: alert, questions: questions)
                } label: {
                    Label {
                        Text("Answer ^[\(questions.count) questions](inflect: true)")
                    } icon: {
                        Image(systemName: "list.number")
                    }
                    .font(CompanionType.font(13, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                .disabled(store.pendingAction.isBusy)
            }
            WatchAnswerStatusLine(phase: phase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $walk) { draft in
            WatchQuestionWalkView(draft: draft, project: alert.project, agent: alert.agent,
                                  macName: store.state?.macName) { answers in
                store.submitAnswers(sessionId: draft.sessionId,
                                    pendingId: draft.pendingId, answers: answers)
            }
        }
    }
}

/// The prompt a walk was opened about, captured when it began.
///
/// The questions are copied, not read back off the card: a snapshot arriving
/// mid-walk replaces the card's `alert` in place, and a pick made on question
/// 2 must stay a pick on the question 2 the wearer read. The identity is what
/// the store re-checks against the live alert before anything is sent.
struct WatchQuestionWalkDraft: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let pendingId: String
    let items: [WatchQuestionItem]

    /// Nil when the alert carries no identity — which is also when no answer
    /// may be sent for it.
    init?(alert: WatchAlert, questions: [WatchQuestionItem]) {
        guard let pendingId = alert.pendingId, !pendingId.isEmpty, !questions.isEmpty else { return nil }
        self.sessionId = alert.sessionId
        self.pendingId = pendingId
        self.items = questions
    }
}

/// The walk itself: one question per screen, then the review.
///
/// State lives here and nowhere else, so dismissing the sheet — swipe, Cancel,
/// or the crown — drops every pick at once. It closes only when a send was
/// actually started; a send the wrist had to decline leaves the page up with
/// the reason on it, because a page that dismisses itself is indistinguishable
/// from one that worked.
struct WatchQuestionWalkView: View {
    let draft: WatchQuestionWalkDraft
    let project: String
    let agent: AgentKind
    let macName: String?
    /// Returns false when nothing at all was started, and the page stays up.
    let onSend: (QuestionAnswers) -> Bool

    @State private var index = 0
    /// Picks per question id, as option values, in the order they were made.
    @State private var picks: [String: [String]] = [:]
    @State private var refused = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if index < draft.items.count {
            let item = draft.items[index]
            WatchQuestionPage(item: item, position: index + 1, count: draft.items.count,
                              picked: picks[item.id] ?? [],
                              onPick: { pick($0, in: item) },
                              onNext: { advance() },
                              onBack: index > 0 ? { index -= 1 } : nil)
        } else {
            WatchQuestionReviewPage(items: draft.items, picks: picks,
                                    caption: SessionActionSupport.targetCaption(
                                        macName: macName, project: project, agent: agent),
                                    refused: refused,
                                    onSend: send,
                                    onBack: { index = max(0, draft.items.count - 1) })
        }
    }

    /// A single-select pick is the answer and moves on; a multi-select pick
    /// toggles, and Next moves on.
    private func pick(_ option: WatchQuestionOption, in item: WatchQuestionItem) {
        refused = false
        if item.multiSelect {
            var chosen = picks[item.id] ?? []
            if let at = chosen.firstIndex(of: option.value) { chosen.remove(at: at) }
            else { chosen.append(option.value) }
            picks[item.id] = chosen
        } else {
            picks[item.id] = [option.value]
            advance()
        }
    }

    private func advance() {
        index = min(index + 1, draft.items.count)
    }

    private func send() {
        var answers: QuestionAnswers = [:]
        for item in draft.items {
            guard let chosen = picks[item.id], !chosen.isEmpty else { refused = true; return }
            answers[item.id] = chosen
        }
        if onSend(answers) { dismiss() } else { refused = true }
    }
}

/// One question, its choices, and the way forward.
struct WatchQuestionPage: View {
    let item: WatchQuestionItem
    let position: Int
    let count: Int
    let picked: [String]
    let onPick: (WatchQuestionOption) -> Void
    let onNext: () -> Void
    let onBack: (() -> Void)?

    /// The same bound as the one-question card: past it the list stops being
    /// a list, and the wrist says the rest are on the iPhone.
    private var shown: [WatchQuestionOption] { Array(item.options.prefix(WatchQuickAnswers.maxOptions)) }
    private var omitted: Int { max(0, item.options.count - shown.count) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("Question \(position) of \(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(item.text)
                    .font(CompanionType.font(15, .black))
                    .lineLimit(4)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                if item.multiSelect {
                    Text("Choose all that apply.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { option in
                    choice(option)
                }
                if omitted > 0 {
                    Text("\(omitted) more choices — see them on your iPhone.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.multiSelect {
                    Button {
                        onNext()
                    } label: {
                        Text(position == count ? "Review" : "Next")
                            .font(CompanionType.font(14, .heavy))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(picked.isEmpty)
                }
                if let onBack {
                    Button("Back", action: onBack)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }

    /// Drawn like a quick reply on the card, with a mark when it takes several.
    private func choice(_ option: WatchQuestionOption) -> some View {
        Button {
            onPick(option)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if item.multiSelect {
                    Image(systemName: picked.contains(option.value) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                }
                Text(option.label)
                    .font(CompanionType.font(13, .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }
}

/// The one screen between the picks and someone's agent: where this is going,
/// and what it says, question by question.
struct WatchQuestionReviewPage: View {
    let items: [WatchQuestionItem]
    let picks: [String: [String]]
    let caption: String
    let refused: Bool
    let onSend: () -> Void
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Send these answers?")
                    .font(CompanionType.font(15, .black))
                    .fixedSize(horizontal: false, vertical: true)
                // Which Mac, which project, which agent — the same caption the
                // one-string page and the iPhone's composer show.
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                ForEach(items) { item in
                    answer(item)
                }
                if refused {
                    Text("Could not send. The question changed or another action is still pending.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    onSend()
                } label: {
                    Text("Send")
                        .font(CompanionType.font(14, .heavy))
                        .frame(maxWidth: .infinity)
                }
                .tint(CompanionPalette.status(.completeUnread))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .handGestureShortcut(.primaryAction)
                Button("Back", action: onBack)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }

    /// The question in the agent's words, and the picks in the words the
    /// wearer read — labels, never the values that travel.
    private func answer(_ item: WatchQuestionItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(labels(for: item))
                .font(CompanionType.font(13, .heavy))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labels(for item: WatchQuestionItem) -> String {
        let chosen = picks[item.id] ?? []
        return item.options.filter { chosen.contains($0.value) }.map(\.label).joined(separator: ", ")
    }
}
