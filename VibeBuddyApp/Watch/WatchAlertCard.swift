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

    private var accent: Color { CompanionPalette.status(.requiresInput) }

    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
    }

    /// `<project> wants to <verb>` when the tool is known, else the plain kind.
    private var label: String {
        if alert.waitKind == .permission, let tool = alert.tool {
            return "\(alert.project) wants to \(CompanionCopy.requestVerb(tool: tool))"
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

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                    .font(CompanionType.font(9, .heavy)).textCase(.uppercase).kerning(0.4)
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(WatchFormat.duration(alert.waitedFor(now: now)))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(title)
                .font(CompanionType.font(15, .black))
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)

            // A command is code and must be read literally; it sits in its own
            // mono strip. A question already is the title above.
            if alert.waitKind == .permission, let request = alert.request {
                Text(request)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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

            Text("\(alert.agent.shortName) · \(alert.project)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

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
            VStack(spacing: 6) {
                button(.allow, title: "Approve", tint: CompanionPalette.status(.completeUnread))
                button(.deny, title: "Deny", tint: CompanionPalette.status(.error))
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
                .font(CompanionType.font(14, .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .tint(tint)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
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
