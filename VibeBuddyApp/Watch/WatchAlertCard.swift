import SwiftUI
import VibeBuddyKit

/// The urgent takeover. A blocked session is exceptional and time-sensitive
/// enough to replace the calm home content rather than sit below it.
///
/// This slice is read-only on both kinds of wait: acting from the wrist needs
/// the validated one-shot decision path, which is a later slice. Saying so is
/// better than an Approve button that cannot honestly report what happened.
struct WatchAlertCard: View {
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

            Text(alert.waitKind == .permission
                 ? "Approve or deny on your iPhone."
                 : "Answer on your iPhone.")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
