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

    private var accent: Color { Color(taskStatus: TaskPresentationState.requiresInput.colorToken) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Capsule()
                .fill(accent)
                .frame(width: 2)
            content
        }
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Who and where, plus how long it has been waiting. The time sits
            // here rather than beside the headline so the headline keeps the
            // full width on a 40mm screen.
            HStack(spacing: 4) {
                Image(systemName: alert.agent.symbolName)
                    .font(.system(size: 9))
                Text("\(alert.agent.shortName) · \(alert.project)")
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 4)
                Text(WatchFormat.duration(alert.waitedFor(now: now)))
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: alert.waitKind == .permission ? "lock.shield.fill" : "questionmark")
                    .font(.system(size: 12, weight: .bold))
                Text(alert.waitKind == .permission ? "Needs approval" : "Asked a question")
                    .font(.headline)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .foregroundStyle(accent)

            if let request = alert.request {
                VStack(alignment: .leading, spacing: 3) {
                    if let tool = alert.tool {
                        Text(tool)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    // A command is code and must be read literally; a question
                    // is prose and reads better in the system face.
                    Text(request)
                        .font(alert.waitKind == .permission
                              ? .system(.caption2, design: .monospaced)
                              : .caption2)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else if let summary = alert.summary {
                Text(summary)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // What the agent offered as answers. Shown so the question makes
            // sense, not offered as a choice: sending one means typing into
            // someone's terminal, which this slice does not do.
            if !alert.options.isEmpty {
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
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if alert.isDecidable {
                WatchApprovalActions(store: store, alert: alert)
            } else {
                Text(alert.waitKind == .permission
                     ? "Approve or deny on your iPhone."
                     : "Answer on your iPhone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if alsoWaiting > 0 {
                Text("\(alsoWaiting) more waiting")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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

    private var phase: WatchApprovalAction.Phase? {
        store.approval.action.flatMap { $0.approvalId == alert.approvalId ? $0.phase : nil }
    }

    /// Why a decision cannot be sent right now, if it cannot.
    private var blocked: LocalizedStringResource? {
        if !store.canReachPhone { return "Can't reach your iPhone — decide there, or move closer." }
        if store.state?.relay == .disconnected {
            return "Your iPhone can't reach your Mac, so this can't be sent."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                button(.deny, title: "Deny", tint: Color(taskStatus: TaskPresentationState.error.colorToken))
                button(.allow, title: "Approve", tint: Color(taskStatus: TaskPresentationState.completeUnread.colorToken))
            }
            .disabled(blocked != nil || store.approval.isBusy)

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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func button(_ choice: WatchApprovalChoice,
                        title: LocalizedStringResource, tint: Color) -> some View {
        Button {
            store.submit(alert, choice)
        } label: {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .buttonStyle(.borderedProminent)
    }

    /// Never "Approved". The wrist knows only that the Mac took the decision;
    /// the alert itself clears when a later snapshot says the prompt is gone.
    private var statusText: LocalizedStringResource? {
        switch phase {
        case .sending: return "Sending…"
        case .awaitingResolution: return "Sent. Waiting for your Mac to confirm."
        case .failed: return "Couldn't send that. Try again."
        case .refused: return "This is no longer waiting on you."
        case nil: return blocked
        }
    }
}
