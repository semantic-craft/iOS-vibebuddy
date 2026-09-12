import SwiftUI
import VibeBuddyKit

/// The urgent takeover. A blocked session is exceptional and time-sensitive
/// enough to replace the calm home content rather than sit below it.
///
/// A permission whose exact command or path was relayed in full can be resolved
/// here, one shot only. Everything else — every question, and any approval whose
/// real substance (an Edit's diff, an over-long command) stayed on the iPhone —
/// keeps saying so instead of offering a button that cannot honestly report what
/// was approved.
struct WatchAlertCard: View {
    @ObservedObject var store: WatchStateStore
    let alert: WatchAlert
    let now: Date
    let alsoWaiting: Int
    /// Whether this card is the one in front of the person right now. Only that
    /// card may claim the Double Tap primary action — the home screen keeps
    /// rendering its own top alert behind an open task sheet, and two live
    /// claims would let a pinch approve a command the wearer cannot see.
    var isFrontmost: Bool = true

    private var accent: Color { CompanionPalette.status(.requiresInput) }

    var body: some View {
        // A card on a hairline, not a tinted block: the dot and the kicker
        // carry the urgency (ADR-0017 §4).
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .companionCard()
            .accessibilityElement(children: .combine)
    }

    /// `<project> wants to <verb>` when the tool is known, else the plain kind.
    private var label: String {
        if alert.waitKind == .permission, let tool = alert.tool {
            return String(localized: "\(alert.project) wants to \(CompanionCopy.requestVerb(tool: tool))")
        }
        return alert.waitKind == .permission
            ? String(localized: "\(alert.project) needs approval")
            : String(localized: "\(alert.project) asked a question")
    }

    /// The line that matters: the agent's summary, or the question itself.
    private var title: String {
        if alert.waitKind == .question, let request = alert.request { return request }
        if let summary = alert.summary, !summary.isEmpty { return summary }
        return alert.waitKind == .permission
            ? String(localized: "Needs approval") : String(localized: "Asked a question")
    }

    private var connectionMessage: LocalizedStringResource? {
        WatchLinkBlock.message(store, now: now)
    }

    /// Whether the quick answers are actually on screen. When they are, the
    /// agent's own options are the buttons; when a broken link takes the
    /// buttons away, the options go back to being the caption that explains the
    /// question.
    private var showsAnswerControl: Bool {
        connectionMessage == nil && !alert.isDecidable && alert.isAnswerable
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                StatusDot(state: .requiresInput)
                    .padding(.top, 3)
                Text(label)
                    .font(CompanionType.font(10, .medium))
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(WatchFormat.duration(alert.waitedFor(now: now)))
                    .font(CompanionType.font(10))
                    .monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink2)
            }

            Text(title)
                .font(CompanionType.font(15, .semibold))
                .foregroundStyle(CompanionPalette.ink)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)

            // A command is code and must be read literally; it sits in its own
            // mono strip. A question already is the title above.
            if alert.waitKind == .permission, let request = alert.request {
                Text(request)
                    .font(CompanionType.mono(10))
                    .foregroundStyle(CompanionPalette.ink)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(CompanionPalette.bg2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // What the agent offered as answers, when they are not already the
            // buttons below. On an answerable question the options *are* the
            // quick replies, and listing them twice would read as two different
            // things being offered.
            if !alert.options.isEmpty, !showsAnswerControl {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(alert.options, id: \.self) { option in
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Image(systemName: "circle")
                                .font(.system(size: 6))
                            Text(option)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(CompanionType.font(10))
                .foregroundStyle(CompanionPalette.ink2)
            }

            Text("\(alert.agent.shortName) · \(alert.project)")
                .font(CompanionType.font(10))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            // What the request is, above; what can be done about it, below.
            CompanionHairline()
                .padding(.vertical, 2)

            if let connectionMessage {
                Text(connectionMessage).font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
                if alert.handling == .macGrokBot || alert.handling == .macNativePrompt {
                    Text((alert.handling ?? .unavailable).message)
                        .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
                }
            } else if alert.isDecidable {
                WatchApprovalActions(store: store, alert: alert, isFrontmost: isFrontmost)
            } else if !alert.isAnswerable {
                // The read-only wait keeps saying where it can be answered —
                // "Respond in the agent's own prompt on your Mac" — rather than
                // growing a button the iPhone would refuse.
                Text((alert.handling ?? .unavailable).message)
                    .font(CompanionType.font(10))
                    .foregroundStyle(CompanionPalette.ink2)
            }

            // Outside the connection branch on purpose. The buttons do
            // disappear when the link goes down — the control draws none —
            // but an answer already in flight keeps its sentence. Walking away
            // from your iPhone must not erase "sent, waiting for your Mac" and
            // leave the question looking untouched.
            if alert.isAnswerable {
                WatchAnswerControl(store: store, alert: alert)
            }

            // A waiting session has no running turn, so this stays silent here
            // today. It is on the card because the card is one of the two
            // places a session is shown on this Watch, and the offer is a fact
            // about the session rather than about which screen it is on: the
            // day a wait becomes stoppable, both screens say so at once.
            if let followed = store.state?.followedTasks.first(where: { $0.sessionID == alert.sessionId }) {
                WatchStopControl(store: store, task: followed)
            }

            if alsoWaiting > 0 {
                Text("\(alsoWaiting) more waiting")
                    .font(CompanionType.font(10))
                    .monospacedDigit()
                    .foregroundStyle(CompanionPalette.ink2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one-shot decision, and an honest sentence about where it got to.
///
/// The buttons are live only when a decision could actually travel: the iPhone
/// has to be reachable *and* still connected to the Mac. A tap that cannot leave
/// the wrist is worse than no button, so when either link is down they are
/// disabled and the reason is written out.
///
/// There is no "always allow" here, and there cannot be: the wrist can only
/// encode `allow` or `deny` (ADR-0010 keeps persisted rules where the full
/// command is readable).
struct WatchApprovalActions: View {
    @ObservedObject var store: WatchStateStore
    let alert: WatchAlert
    var isFrontmost: Bool = true

    private var phase: WatchSessionActionAttempt.Phase? {
        store.pendingAction.action.flatMap { $0.approvalId == alert.approvalId ? $0.phase : nil }
    }

    /// Why a decision cannot be sent right now, if it cannot.
    private var blocked: LocalizedStringResource? {
        if !store.canReachPhone { return "Can't reach your iPhone — decide there, or move closer." }
        return WatchLinkBlock.message(store, now: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 6) {
                // Double Tap resolves the card one-handed. Only Approve is the
                // primary action: pinching twice must never be the gesture that
                // refuses something, and watchOS offers exactly one primary — so
                // only the frontmost card claims it.
                button(.allow, title: "Approve", tint: CompanionPalette.status(.completeUnread))
                    .handGestureShortcut(.primaryAction, isEnabled: isFrontmost)
                button(.deny, title: "Deny", tint: CompanionPalette.status(.error))
            }
            .disabled(blocked != nil || store.pendingAction.isBusy)

            if let message = statusText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if phase == .sending { ProgressView().controlSize(.mini) }
                    Text(message)
                        .font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Stacked and full-width, in the state's own colour, radius 8: the
    /// phone's rectangles rather than the system's capsule.
    private func button(_ choice: WatchApprovalChoice,
                        title: LocalizedStringResource, tint: Color) -> some View {
        Button {
            store.submit(alert, choice)
        } label: {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CompanionButtonStyle(kind: .filled(tint), size: .wide))
    }

    /// Never "Approved". The wrist knows only that the Mac took the decision;
    /// the alert itself clears when a later snapshot says the prompt is gone.
    private var statusText: LocalizedStringResource? {
        switch phase {
        case .sending: return "Sending…"
        case .awaitingResolution: return "Sent. Waiting for your Mac to confirm."
        case .failed: return "Couldn't send that. Try again."
        // The reply was lost, so whether the Mac decided this is not something
        // the wrist knows. Nothing is resent for it.
        case .unknown: return "Couldn't confirm that. Check the request."
        case .refused: return "This is no longer waiting on you."
        case nil: return blocked
        }
    }
}

/// Why nothing can be sent from the wrist right now, in the wording every
/// action-bearing surface already uses. One sentence, one place: an approval
/// and a stop are blocked by the same broken link and must not describe it
/// differently.
enum WatchLinkBlock {
    /// Nil means an action could actually travel right now. Every other answer
    /// is the innermost link the Watch can prove is down, in the words that
    /// link already had — and it is derived from `WatchConnection`, not from
    /// the relayed verdict alone, so a state that has simply aged out disables
    /// the buttons instead of leaving a live-looking one that does nothing.
    @MainActor
    static func message(_ store: WatchStateStore, now: Date) -> LocalizedStringResource? {
        guard let state = store.state else { return "Waiting for an updated request from your iPhone." }
        switch state.connection(now: now, phoneReachable: store.canReachPhone) {
        case .macDisconnected:
            return "Your iPhone can't reach your Mac, so this can't be sent."
        case .phoneDisconnected:
            return "Your iPhone hasn't sent an update. Open VibeBuddy on your iPhone."
        case .watchUnreachable:
            return "Can't reach your iPhone. Reconnect to verify this request."
        case .noData:
            return "Waiting for an updated request from your iPhone."
        case .live:
            return store.canReachPhone ? nil : "Can't reach your iPhone. Reconnect to verify this request."
        }
    }
}

/// Ending a running turn from the wrist.
///
/// Three states, and the third one is the point: a task that is not running
/// says *nothing at all* here. A button that would be refused, or a sentence
/// explaining an absence nobody asked about, are both worse than an empty
/// space — so the offer is a fact carried on the projection (`WatchStopOffer`,
/// derived on the iPhone from the shared rule) and this view only draws it.
///
/// The button is red and destructive, and it never acts on the first tap: the
/// confirmation is its own screen, and only there is Stop the Double Tap
/// primary action. Afterwards the wrist says "sent", never "stopped" — the
/// button goes away when the next snapshot shows the turn is over, and nothing
/// else takes it away.
struct WatchStopControl: View {
    @ObservedObject var store: WatchStateStore
    let task: WatchFollowedTask
    @State private var confirming: WatchStopIntent?

    private var phase: WatchSessionActionAttempt.Phase? {
        store.pendingAction.action.flatMap {
            $0.isStop && $0.sessionId == task.sessionID ? $0.phase : nil
        }
    }

    private var blocked: LocalizedStringResource? { WatchLinkBlock.message(store, now: Date()) }

    var body: some View {
        switch task.stop {
        case nil:
            EmptyView()
        case .blocked(let block):
            // Named agent, named reason, no button. "Stop this on your Mac" is
            // an answer; a dead button is not. The words are chosen here, on
            // the device doing the reading, from the code the iPhone relayed.
            Text(block.message(agent: task.agent))
                .font(CompanionType.font(10))
                .foregroundStyle(CompanionPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .offered:
            offer
        }
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                confirming = WatchStopIntent(task: task)
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(CompanionButtonStyle(kind: .filled(CompanionPalette.status(.error)), size: .wide))
            .disabled(blocked != nil || store.pendingAction.isBusy)

            if let message = statusText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if phase == .sending { ProgressView().controlSize(.mini) }
                    Text(message)
                        .font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $confirming) { intent in
            WatchStopConfirmView(intent: intent) {
                store.submitStop(sessionID: intent.sessionID, statusSince: intent.statusSince)
            }
        }
    }

    /// Never "Stopped". An accepted stop means the Mac has it; the turn is over
    /// when a snapshot says so, and that same snapshot is what removes this.
    private var statusText: LocalizedStringResource? {
        // A broken link outranks the attempt: it is why the button is dead and
        // why a tap on the confirmation page went nowhere.
        if let blocked { return blocked }
        switch phase {
        case .sending: return "Sending…"
        case .awaitingResolution: return "Sent. Waiting for your Mac to confirm."
        // Never "couldn't send": a timeout can drop the reply to a stop the Mac
        // already carried out, and this is the one action where inviting a
        // blind retry is worse than saying the truth.
        case .failed, .unknown: return "Couldn't confirm that. Check the task."
        case .refused: return "This isn't running any more."
        case nil: return nil
        }
    }
}

/// The turn a confirmation page was opened about.
///
/// The turn's own moment, captured when the first tap happened — not read back
/// off a view property that the next snapshot replaces in place. A confirmation
/// page is exactly the window in which a turn can end and the next one begin,
/// which is the window this value exists to survive.
struct WatchStopIntent: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let statusSince: Date
    let title: String

    init(task: WatchFollowedTask) {
        sessionID = task.sessionID
        statusSince = task.statusSince
        title = task.title
    }
}

/// The second screen, which is the whole safety of a stop: the first tap only
/// asks, and this is where the answer is given. Stop is the Double Tap primary
/// action *here* and nowhere else, so the gesture cannot end a turn from a
/// glance.
///
/// It closes only when something was actually started. A stop the wrist had to
/// decline — the turn ended while this page was open — leaves the page up with
/// the reason on it, because for a destructive action a page that dismisses
/// itself is indistinguishable from one that worked.
struct WatchStopConfirmView: View {
    let intent: WatchStopIntent
    /// Returns false when nothing at all was started, and the page stays up.
    let onStop: () -> Bool
    @State private var refused = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Stop this task?")
                    .font(CompanionType.font(15, .semibold))
                    .foregroundStyle(CompanionPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(intent.title.isEmpty ? String(localized: "Unnamed task") : intent.title)
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2)
                    .lineLimit(2)
                Text("The turn it is running now ends. Work already finished stays done.")
                    .font(CompanionType.font(10))
                    .foregroundStyle(CompanionPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)

                if refused {
                    Text("Could not send. The task changed or another action is still pending.")
                        .font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button(role: .destructive) {
                    if onStop() { dismiss() } else { refused = true }
                } label: {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CompanionButtonStyle(kind: .filled(CompanionPalette.status(.error)), size: .wide))
                .handGestureShortcut(.primaryAction)

                Button("Keep going") { dismiss() }
                    .buttonStyle(CompanionButtonStyle(kind: .quiet, size: .wide))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }
}
