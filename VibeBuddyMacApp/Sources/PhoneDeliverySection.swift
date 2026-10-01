import SwiftUI
import VibeBuddyMacCore

/// A presentation of existing delivery evidence, separate from agent observation
/// health. Neither saved pairing nor service acceptance proves a visible banner.
struct PhoneDeliverySection: View {
    @ObservedObject var model: MenuBarModel
    let showDiagnostics: () -> Void

    var body: some View {
        SettingsSection("iPhone notifications",
                        footnote: "A saved pairing or a checked address does not confirm notification delivery. APNs acceptance, iCloud storage and an iPhone scheduling report do not prove a banner appeared. Check the iPhone to confirm display.") {
            if model.notificationDeliveryHealth.apnsConfigured {
                SettingsRow("Push service",
                            detail: "This Mac is configured to send through APNs. Configuration alone does not verify a send.") {
                    SettingsValue("APNs configured")
                }
            } else {
                iCloudStatus
            }

            if let last = model.recentNotificationDeliveries.first(where: { $0.channel != .local }) {
                SettingsRow("Latest phone delivery record", detailText: recordDetail(last)) {
                    SettingsValue(outcomeTitle(last))
                }
            } else {
                SettingsRow("Latest phone delivery record",
                            detail: "The recent records contain no phone delivery attempt. This is not a complete delivery history.") {
                    SettingsValue("No recent record")
                }
            }

            if let failure = model.notificationDeliveryHealth.latchedFailure,
               failure.channel != .local {
                SettingsRow("Recorded phone delivery failure", detailText: recordDetail(failure)) {
                    SettingsPill("Failed", tone: .critical)
                }
            }

            SettingsRow("Delivery diagnostics",
                        detail: "Review delivery records and failure details. iPhone notification permissions and Focus are controlled on the iPhone.") {
                Button("Show delivery diagnostics", action: showDiagnostics)
                    .buttonStyle(SettingsQuietButtonStyle())
                    .accessibilityIdentifier("settings.phone.delivery.diagnostics")
            }
        }
    }

    @ViewBuilder private var iCloudStatus: some View {
        SettingsRow("Push service",
                    detail: "Without an APNs key, closed-app notifications use iCloud. The Mac and iPhone must use the same Apple Account; availability does not verify delivery.") {
            switch model.cloudKitStatus.state {
            case .notEntitled:
                SettingsValue("iCloud unavailable in this build")
            case .noAccount:
                SettingsPill("Sign in to iCloud", tone: .warn)
            case .restricted, .temporarilyUnavailable:
                SettingsPill("iCloud unavailable", tone: .warn)
            case .couldNotDetermine:
                SettingsValue("iCloud status unknown")
            case .available:
                if model.cloudKitPhones > 0 {
                    SettingsValue("iCloud account available")
                } else {
                    SettingsPill("No matching iPhone reported", tone: .warn)
                }
            }
        }
        if let error = model.cloudKitStatus.lastError, !error.isEmpty {
            SettingsBlockRow {
                Text(verbatim: error)
                    .font(SettingsChrome.font(12.5))
                    .foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func outcomeTitle(_ record: NotificationDeliveryRecord) -> LocalizedStringKey {
        switch (record.channel, record.outcome) {
        case (.apns, .accepted): "Accepted by APNs"
        case (.cloudkit, .accepted): "Saved to iCloud"
        case (.phone, .scheduled): "iPhone reported scheduling"
        case (_, .pruned): "Push registration stopped"
        default: record.outcome.settingsTitle
        }
    }

    private func recordDetail(_ record: NotificationDeliveryRecord) -> String {
        let channel: String
        switch record.channel {
        case .apns: channel = "APNs"
        case .cloudkit: channel = "iCloud"
        case .phone: channel = String(localized: "iPhone report")
        case .local: channel = String(localized: "This Mac")
        }
        var parts = [channel, record.timestamp.formatted(date: .abbreviated, time: .shortened)]
        if let reason = record.failureReason { parts.append(reason) }
        if let reason = record.apnsReason { parts.append(reason) }
        if let device = record.deviceID {
            parts.append(String(localized: "Device …\(device.suffix(8))"))
        }
        return parts.joined(separator: " · ")
    }
}
