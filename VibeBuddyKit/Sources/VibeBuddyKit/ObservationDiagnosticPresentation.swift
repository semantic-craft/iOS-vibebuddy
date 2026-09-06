import SwiftUI

/// Renders Mac diagnostic facts; never infers session state or changes configuration.
public extension ObservationSourceDiagnostic {
    /// Old Mac snapshots identify the optional source through source + health.
    var isOptionalStatusLineNotConfigured: Bool {
        source == .statusline && health == .notInstalled
    }
    var isInformational: Bool {
        isOptionalStatusLineNotConfigured || health == .temporarilySilent || reasonCode == "optionalSourceNotConfigured"
            || reasonCode == "versionUnverified"
    }
    var diagnosticIcon: String {
        health.isHealthy ? "checkmark.circle.fill"
            : isInformational ? "info.circle" : "exclamationmark.triangle.fill"
    }
    var diagnosticColor: Color { health.isHealthy ? .green : isInformational ? .gray : .orange }
    var diagnosticTitle: String {
        if isOptionalStatusLineNotConfigured { return "Status line information not enabled" }
        return switch reasonCode {
        case "awaitingActivity": source == .hook ? "Configured, awaiting first activity" : "Awaiting activity"
        case "versionUnverified": "Version \(sourceVersion ?? "unknown") not yet verified"
        case "invalidSourceData": "Invalid source data"
        case "configurationIncomplete": "Configuration incomplete"
        case "optionalSourceNotConfigured": "Status line information not enabled"
        default: health == .temporarilySilent ? "No recent activity" : health.displayName
        }
    }
    var diagnosticExplanation: String {
        if isOptionalStatusLineNotConfigured {
            return "Optional Claude status line information is not enabled. Hook and Transcript monitoring can continue."
        }
        switch reasonCode {
        case "awaitingActivity":
            return source == .transcript
                ? "No transcript has been read since this launch. Transcript reading starts when a Hook reports session activity."
                : "Configured; no signal received since this launch. A new task can verify this source."
        case "configurationIncomplete":
            let missing = ObservationEventCoverage.allCases.filter { !configuredCoverage.contains($0) }
                .map(\.displayName).joined(separator: ", ")
            return "Missing hook configuration: \(missing). Configured coverage is separate from events received this launch."
        case "versionUnverified":
            return "No format error was found in the inspected records, but this Rollout version has not completed lifecycle verification. Hook repair does not verify a Rollout version."
        case "invalidSourceData":
            return "Rollout data could not be parsed or a required event structure is invalid. Check the Rollout source data; reinstalling Hooks does not repair it."
        case "optionalSourceNotConfigured":
            return "Optional Claude status line information is not enabled. Hook and Transcript monitoring can continue."
        default:
            if source == .statusline, health == .sourceUnreadable {
                return "Claude's status line configuration cannot be read."
            }
            return health.explanation(for: source)
        }
    }
    var canRepairConfiguration: Bool {
        reasonCode == "configurationIncomplete" || health == .asyncIncompatible
    }
}
