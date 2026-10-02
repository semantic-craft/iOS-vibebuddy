import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct GrokMonitoringSection: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var setup: HookSetup

    private var config: GrokMonitoringConfiguration { setup.grokConfiguration }
    private var status: GrokMonitoringStatus? { model.grokMonitoring }
    private var error: String? { setup.grokOperationError ?? config.error }

    var body: some View {
        SettingsSection("Grok Build session monitoring",
                        footnote: "Monitors terminal sessions. Account quota is controlled separately. Tasks started by VibeBuddy keep their own connection.") {
            SettingsRow("Monitor Grok Build", detail: "Automatically sets up activity reporting when enabled.") {
                Toggle("Monitor Grok Build", isOn: Binding(get: { config.enabled }, set: change))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(setup.running)
                    .accessibilityIdentifier("grok-monitoring-enabled")
            }
            VStack(alignment: .leading, spacing: 8) {
                if setup.running {
                    ProgressView("Configuring Grok Build…")
                } else {
                    Text(stateText).font(.callout)
                        .accessibilityIdentifier("grok-monitoring-status")
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("grok-monitoring-error")
                    }
                    if error == nil && config.enabled && config.configured && status?.needsHookReload == true {
                        Text("In Grok Build, run /hooks and press r to reload. If reload is unavailable, start a new session. Activity updates appear after the next event.")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if error != nil || (config.enabled && !config.configured) {
                        Button("Retry Grok Build connection") {
                            setup.retryGrokMonitoring { model.refreshGrokMonitoring() }
                        }
                            .accessibilityIdentifier("retry-grok-monitoring")
                    }
                }
            }.padding(.vertical, 8)
        }
    }

    private func change(_ enabled: Bool) {
        setup.setGrokMonitoring(enabled) { model.refreshGrokMonitoring() }
    }

    private var stateText: String {
        if error != nil { return String(localized: "Grok Build connection needs attention") }
        if !config.available { return String(localized: "Grok Build was not found. Open Grok Build once, then enable monitoring.") }
        if !config.enabled { return String(localized: "Monitoring is off") }
        if !config.configured { return String(localized: "Activity reporting is not configured. Retry to connect.") }
        let waiting = status?.discoveredSessions.count ?? 0
        let connected = status?.connectedSessionCount ?? 0
        if waiting > 0 {
            return String(localized: "Connected: \(connected) · Waiting for activity: \(waiting)")
        }
        if connected > 0 { return String(localized: "Connected: \(connected) sessions") }
        return String(localized: "Configured. Waiting for a Grok Build session to report activity.")
    }
}

/// An observed process has no known task state yet, so it gets a discovery
/// card rather than a synthetic AgentSession or a misleading done/working badge.
struct GrokDiscoveryCard: View {
    let session: GrokDiscoveredSession
    let status: GrokMonitoringStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.project).font(.headline)
            if let error = status.error {
                Text("Grok Build connection needs attention").font(.caption)
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !status.configured {
                    Text("Activity reporting is not configured. Retry to connect.").font(.caption)
                }
            } else if !status.enabled {
                Text("Monitoring is off").font(.caption)
            } else if !status.available {
                Text("Grok Build was not found. Open Grok Build once, then enable monitoring.").font(.caption)
            } else if !status.configured {
                Text("Activity reporting is not configured. Retry to connect.").font(.caption)
            } else {
                Text("Grok Build · Discovered, waiting to connect").font(.caption)
                if status.needsHookReload {
                    Text("In Grok Build, run /hooks and press r to reload. If reload is unavailable, start a new session. Activity updates appear after the next event.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Button("Open Agent integration") {
                NotificationCenter.default.post(name: .openAppSettings, object: SettingsPageID.agentCLIs)
            }.buttonStyle(.link)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("grok-discovered-\(session.id)")
    }
}
