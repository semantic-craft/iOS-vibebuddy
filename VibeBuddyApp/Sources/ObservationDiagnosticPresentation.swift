import SwiftUI
import VibeBuddyKit

extension ObservationSourceDiagnostic {
    var phoneNextStep: String? {
        if isOptionalStatusLineNotConfigured {
            return "On the Mac, optionally choose Enable status line information."
        }
        switch reasonCode {
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
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source.source.displayName) · \(source.diagnosticTitle)")
                    .fontWeight(.semibold)
                Text(source.diagnosticExplanation)
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                if let version = source.sourceVersion, source.reasonCode != "versionUnverified" {
                    Text("Source version \(version)")
                        .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
                if let nextStep = source.phoneNextStep {
                    Text(nextStep).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                }
                if let last = source.lastObservedAt {
                    Text("Last signal \(last, style: .relative)")
                        .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
                Group {
                    let configured = source.source == .hook ? source.configuredCoverageDescription : "not applicable"
                    let observed = source.observedCoverageDescription
                    Text("Coverage: configured \(configured.isEmpty ? "none" : configured); received this launch \(observed.isEmpty ? "none" : observed)")
                        .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
            }
        }
    }
}
