import SwiftUI
import VibeBuddyKit

/// Answering an agent's question from the wrist.
///
/// Two ways in and one way out. A tap on a fixed phrase — or on one of the
/// choices the agent itself offered — and dictation both land on the *same*
/// confirmation page, because the thing worth confirming is not how the words
/// were produced but where they are about to go. A phrase that skipped the page
/// would be the one send on this Watch nobody could take back.
///
/// The control only exists for a question the iPhone would actually forward
/// (`WatchAlert.isAnswerable`, the same rule its gate re-runs). Everything else
/// keeps saying where to answer instead.
struct WatchAnswerControl: View {
    @ObservedObject var store: WatchStateStore
    let alert: WatchAlert
    @State private var draft: WatchAnswerDraft?
    /// Demo Mode's launch input is honoured once. Without the latch, dismissing
    /// the confirmation page would re-open it forever.
    @State private var openedDemoDraft = false

    private var choices: WatchQuickAnswers? { WatchQuickAnswers.resolve(for: alert) }

    /// Why an answer cannot be sent right now, if it cannot. Same sentence, same
    /// place as every other action on this Watch.
    private var blocked: LocalizedStringResource? {
        if !store.canReachPhone { return "Can't reach your iPhone — answer there, or move closer." }
        return WatchLinkBlock.message(store, now: Date())
    }

    private var phase: WatchSessionActionAttempt.Phase? {
        store.pendingAction.action.flatMap {
            $0.pendingId != nil && $0.pendingId == alert.pendingId ? $0.phase : nil
        }
    }

    var body: some View {
        if let questions = alert.questions {
            // A prompt with several questions is walked one screen at a time
            // and sent as one set; the one-string path below never sees it.
            WatchQuestionWalkControl(store: store, alert: alert, questions: questions,
                                     blocked: blocked, phase: phase)
        } else if let choices {
            VStack(alignment: .leading, spacing: 6) {
                // No buttons at all while nothing could travel. A tap that
                // cannot leave the wrist is worse than no button, and the card
                // above has already named the broken link.
                if blocked == nil {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(choices.replies) { reply in
                            quickReply(reply)
                        }
                        dictation(choices.source)
                    }
                    .disabled(store.pendingAction.isBusy)

                    // The agent offered more choices than fit. Six of eight
                    // presented as the whole list would be a quiet lie about
                    // what was asked.
                    if choices.omittedOptions > 0 {
                        Text("\(choices.omittedOptions) more choices — see them on your iPhone.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                WatchAnswerStatusLine(phase: phase)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One sheet for the whole control: every way in leads to the same
            // page, and presenting it per-button would present it many times.
            .sheet(item: $draft) { pending in
                WatchAnswerConfirmView(draft: pending, question: alert.request,
                                       project: alert.project, agent: alert.agent,
                                       macName: store.state?.macName) { text in
                    store.submitAnswer(sessionId: pending.sessionId,
                                       pendingId: pending.pendingId, text: text)
                }
            }
            .onAppear {
                // Demo Mode only: open the confirmation page on the answer the
                // launch input named, so it can be reviewed without a wrist.
                // The store hands it over once, and only to the card in front
                // of the wearer — two cards can be on screen at the same moment
                // and two sheets asking to present means neither does.
                guard !openedDemoDraft,
                      let seeded = store.consumeDemoAnswerDraft(for: alert.sessionId)
                else { return }
                openedDemoDraft = true
                draft = WatchAnswerDraft(alert: alert, text: seeded)
            }
        }
    }

    private func quickReply(_ reply: WatchQuickReply) -> some View {
        Button {
            draft = WatchAnswerDraft(alert: alert, text: reply.text)
        } label: {
            Text(reply.text)
                .font(CompanionType.font(13, .heavy))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }

    /// The system text input controller — dictation, Scribble and the keyboard,
    /// whichever the wearer reaches for. Its wording follows what it is an
    /// alternative *to*: one more phrase among general ones, or the "not on
    /// this list" answer to the agent's own choices.
    private func dictation(_ source: WatchQuickAnswers.Source) -> some View {
        TextFieldLink(prompt: Text(alert.request ?? String(localized: "Your answer"))) {
            Label(source == .options ? "Something else" : "Dictate an answer",
                  systemImage: "mic.fill")
                .font(CompanionType.font(13, .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        } onSubmit: { spoken in
            let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            draft = WatchAnswerDraft(alert: alert, text: trimmed)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
    }
}

/// What the wrist may say about an answer in flight — one string or a set of
/// picks, the sentence is the same because what happened to it is the same.
struct WatchAnswerStatusLine: View {
    let phase: WatchSessionActionAttempt.Phase?

    var body: some View {
        if let message = statusText {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if phase == .sending { ProgressView().controlSize(.mini) }
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Never "Answered". The wrist knows the Mac took the text; the question
    /// disappears when a later snapshot says the agent moved on.
    private var statusText: LocalizedStringResource? {
        switch phase {
        case .sending: return "Sending…"
        case .awaitingResolution: return "Sent. Waiting for your Mac to confirm."
        // The answer never left the wrist, or the iPhone said it could not
        // deliver it. Either way nothing was said to the agent.
        case .failed: return "Couldn't send that. Try again."
        // It went out and the receipt was lost. Whether the agent has it is not
        // something this Watch knows, so it says so and sends nothing again.
        case .unknown: return "Couldn't confirm that. Check the task."
        // The question this was written for is gone — answered on the Mac, or
        // replaced by the next one. The session may well still be waiting on
        // you, so this does not say it isn't. Nothing was sent.
        case .refused: return "That question is gone now. Nothing was sent."
        // Nothing in flight: the card above owns the sentence about the link,
        // and saying it twice on one screen reads as two different problems.
        case nil: return nil
        }
    }
}

/// An answer waiting to be confirmed, and the question it was written for.
///
/// The identity is the point, not the wrapper. Dictation holds the system input
/// controller open for as long as someone talks, and a snapshot arriving in
/// that time replaces the card's `alert` in place — so "the question this text
/// answers" has to be captured when the text is made, or the confirmation page
/// silently re-points at whatever is being asked when Send is tapped.
struct WatchAnswerDraft: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let pendingId: String
    let text: String

    /// Nil when the alert carries no question identity — which is also when no
    /// answer may be sent for it.
    init?(alert: WatchAlert, text: String) {
        guard let pendingId = alert.pendingId, !pendingId.isEmpty else { return nil }
        self.sessionId = alert.sessionId
        self.pendingId = pendingId
        self.text = text
    }
}

/// The one screen between a tap and someone's agent.
///
/// It shows the two things that are actually at stake — *where* this is going
/// and *what* it says — and lets both be reconsidered. Tapping the text opens
/// the system input controller on it, so a misheard word is fixed here rather
/// than dictated again from nothing. Leaving sends nothing at all.
///
/// It closes only when something was actually started. A send the wrist had to
/// decline — the question moved on while this page was open — leaves the page
/// up with the reason on it, because a page that dismisses itself is
/// indistinguishable from one that worked.
struct WatchAnswerConfirmView: View {
    let draft: WatchAnswerDraft
    /// The agent's own question, shown as written. Not localized: it is data.
    let question: String?
    let project: String
    let agent: AgentKind
    let macName: String?
    /// Returns false when nothing at all was started, and the page stays up.
    let onSend: (String) -> Bool

    @State private var text: String
    @State private var refused = false
    @Environment(\.dismiss) private var dismiss

    init(draft: WatchAnswerDraft, question: String?, project: String,
         agent: AgentKind, macName: String?, onSend: @escaping (String) -> Bool) {
        self.draft = draft
        self.question = question
        self.project = project
        self.agent = agent
        self.macName = macName
        self.onSend = onSend
        _text = State(initialValue: draft.text)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Send this answer?")
                    .font(CompanionType.font(15, .black))
                    .fixedSize(horizontal: false, vertical: true)

                // Which Mac, which project, which agent — the same caption the
                // iPhone's composer shows, so "did I answer the right session"
                // is checked the same way on both devices.
                Text(SessionActionSupport.targetCaption(macName: macName,
                                                        project: project,
                                                        agent: agent))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                if let question, !question.isEmpty {
                    Text(question)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Your answer", text: $text, axis: .vertical)
                    .font(CompanionType.font(14, .heavy))
                    .lineLimit(1...4)
                    .accessibilityLabel(Text("Your answer"))
                    .onChange(of: text) { refused = false }

                if refused {
                    Text("Could not send. The question changed or another action is still pending.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    if onSend(trimmed) { dismiss() } else { refused = true }
                } label: {
                    Text("Send")
                        .font(CompanionType.font(14, .heavy))
                        .frame(maxWidth: .infinity)
                }
                .tint(CompanionPalette.status(.completeUnread))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(trimmed.isEmpty)
                .handGestureShortcut(.primaryAction)

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }
}
