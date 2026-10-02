import SwiftUI
import VibeBuddyKit

/// Connection evidence is separate from task state and never offers task actions.
struct PhoneGrokMonitoring: View {
    let status: GrokMonitoringStatus

    private var title: String {
        if status.error != nil { return String(localized: "Grok Build connection needs attention") }
        if !status.enabled { return String(localized: "Grok Build monitoring is off") }
        if !status.available { return String(localized: "Grok Build was not found on this Mac") }
        if !status.configured { return String(localized: "Grok Build activity reporting is not configured") }
        if !status.discoveredSessions.isEmpty {
            if status.connectedSessionCount > 0 {
                return String(localized: "Connected: \(status.connectedSessionCount) · Waiting for activity: \(status.discoveredSessions.count)")
            }
            return String(localized: "Grok Build · Waiting to connect")
        }
        if status.connectedSessionCount > 0 { return String(localized: "Grok Build · Connected") }
        return String(localized: "Grok Build · Waiting for activity")
    }

    var guidance: String? {
        if status.error != nil {
            return String(localized: "On your Mac, open VibeBuddy Settings → Agent integration and retry the Grok Build connection.")
        }
        if !status.enabled {
            return String(localized: "On your Mac, open VibeBuddy Settings → Agent integration and turn on Monitor Grok Build. Account quota is a separate setting.")
        }
        if !status.available {
            return String(localized: "Open Grok Build on your Mac, then check Agent integration in VibeBuddy Settings.")
        }
        if !status.configured {
            return String(localized: "On your Mac, open VibeBuddy Settings → Agent integration and retry the Grok Build connection.")
        }
        guard status.needsHookReload else { return nil }
        return String(localized: "In Grok Build on your Mac, run /hooks and press r to reload. If reload is unavailable, start a new session. Updates appear after the next activity.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(CompanionType.font(14, .semibold))
                .foregroundStyle(CompanionPalette.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("phone-grok-monitoring-status")
            if let error = status.error {
                Text(verbatim: error)
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.status(.requiresInput))
                    .textSelection(.enabled)
            }
            if status.connectedSessionCount > 0 {
                Text("Connected sessions: \(status.connectedSessionCount)")
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2)
            }
            ForEach(status.discoveredSessions) { session in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: session.project)
                        .font(CompanionType.font(14, .medium))
                        .foregroundStyle(CompanionPalette.ink)
                    Text("Discovered, waiting to connect")
                        .font(CompanionType.font(12))
                        .foregroundStyle(CompanionPalette.ink2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("phone-grok-discovery-\(session.id)")
            }
            if let guidance {
                Text(guidance)
                    .font(CompanionType.font(12))
                    .foregroundStyle(CompanionPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CompanionPalette.line, lineWidth: 1))
    }
}
