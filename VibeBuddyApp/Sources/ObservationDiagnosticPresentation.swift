import SwiftUI
import VibeBuddyKit

extension ObservationSourceDiagnostic {
    var phoneNextStep: String? {
        if isOptionalStatusLineNotConfigured {
            return "On the Mac, optionally choose Enable status line information."
        }
        switch reasonCode {
        case "optionalSourceNotConfigured" where source == .cloud:
            return "On the Mac, open agent settings and connect Cursor cloud agents with a Cursor API key."
        case "optionalSourceNotConfigured": return "On the Mac, optionally choose Enable status line information."
        case "configurationIncomplete": return "On the Mac, repair this agent's hook configuration."
        case "versionUnverified": return "Wait for compatibility support for this source version."
        case "invalidSourceData": return "On the Mac, check this source's data and format."
        default:
            switch health {
            case .healthy, .temporarilySilent: return nil
            case .sourceUnreadable: return "On the Mac, check this source's availability and read permissions."
            case .unknownVersion: return "On the Mac, check this source's version and format."
            case .eventsMissing, .notInstalled, .asyncIncompatible:
                return "On the Mac, inspect this source's configuration and diagnostic details."
            }
        }
    }
}

struct ObservationDiagnosticRow: View {
    let source: ObservationSourceDiagnostic

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: source.diagnosticIcon)
                .foregroundStyle(source.diagnosticColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source.source.displayName) · \(source.phoneDiagnosticTitle)")
                    .fontWeight(.semibold)
                Text(source.phoneDiagnosticExplanation)
                    .font(.subheadline).foregroundStyle(CompanionPalette.ink2)
                if let version = source.sourceVersion, source.reasonCode != "versionUnverified" {
                    Text("Source version \(version)")
                        .font(.caption).foregroundStyle(CompanionPalette.ink3)
                }
                if let nextStep = source.phoneNextStep {
                    Text(LocalizedStringKey(nextStep)).font(.subheadline).foregroundStyle(CompanionPalette.ink2)
                }
                if let last = source.lastObservedAt {
                    Text("Last signal \(last, style: .relative)")
                        .font(.caption).foregroundStyle(CompanionPalette.ink3)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Configured: \(source.phoneConfiguredCoverage)")
                    Text("Received this Mac launch: \(source.phoneObservedCoverage)")
                }
                .font(.caption).foregroundStyle(CompanionPalette.ink2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// Read-only uncertainty presentation. Never changes lifecycle or action authority.
struct PhoneObservationNotice: Equatable {
    let title: String
    let detail: String
    let symbol: String

    init?(session: AgentSession, isConnected: Bool) {
        if session.historyOnly == true {
            title = String(localized: "History only")
            detail = String(localized: "This is a stored conversation. Its live status is unavailable; reading it does not enable control.")
            symbol = "clock.arrow.circlepath"
        } else if !isConnected {
            title = String(localized: "Last received state")
            detail = String(localized: "The Mac is disconnected. This task may have changed; reconnect to refresh its state.")
            symbol = "wifi.exclamationmark"
        } else if session.observations?.contains(where: { !$0.health.isHealthy && $0.health != .temporarilySilent }) == true {
            title = String(localized: "Observation needs attention")
            detail = String(localized: "Some observation sources are unavailable. This does not mean the task finished or failed. Check Observation health in Settings.")
            symbol = "waveform.path.ecg"
        } else { return nil }
    }
}

struct PhoneObservationStatus: View {
    let session: AgentSession
    let isConnected: Bool

    var body: some View {
        if let notice = PhoneObservationNotice(session: session, isConnected: isConnected) {
            VStack(alignment: .leading, spacing: 4) {
                Label(notice.title, systemImage: notice.symbol).font(.subheadline.weight(.semibold))
                Text(notice.detail).font(.caption)
            }
            .foregroundStyle(CompanionPalette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("phoneObservationStatus")
        }
    }
}

extension ObservationSourceDiagnostic {
    var phoneDiagnosticTitle: String {
        if reasonCode == "versionUnverified" {
            return String(localized: "Version \(sourceVersion ?? String(localized: "unknown")) not yet verified")
        }
        return NSLocalizedString(diagnosticTitle, comment: "Observation source state")
    }

    var phoneDiagnosticExplanation: String {
        if reasonCode == "configurationIncomplete" {
            let missing = ObservationEventCoverage.allCases.filter { !configuredCoverage.contains($0) }
                .map { NSLocalizedString($0.displayName, comment: "Observation event") }.joined(separator: ", ")
            return String(localized: "Missing hook configuration: \(missing). Configured coverage is separate from events received this launch.")
        }
        return NSLocalizedString(diagnosticExplanation, comment: "Observation source explanation")
    }

    var phoneConfiguredCoverage: String {
        source == .hook ? phoneCoverage(configuredCoverage) : String(localized: "Not applicable")
    }
    var phoneObservedCoverage: String { phoneCoverage(observedCoverage) }
    private func phoneCoverage(_ values: [ObservationEventCoverage]) -> String {
        values.isEmpty ? String(localized: "None") : values.sorted()
            .map { NSLocalizedString($0.displayName, comment: "Observation event") }.joined(separator: ", ")
    }
}
