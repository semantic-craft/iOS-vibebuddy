import Foundation
import VibeBuddyKit

/// Settings presentation only: a missing Hook says nothing about the other
/// observation channels. Never infer live reception from an installed CLI.
struct AgentIntegrationStatus {
    enum State: Equatable {
        case receiving, waiting, needsAttention, hookConfigured, hookMissing, notDetected
    }

    let state: State
    let sources: [ObservationSource]

    init(configured: Bool, hookInjected: Bool, diagnostics: [ObservationSourceDiagnostic]) {
        let observed = diagnostics.filter { $0.lastObservedAt != nil }
        sources = observed.map(\.source).sorted()
        if observed.contains(where: { $0.health == .healthy }) {
            state = .receiving
        } else if observed.contains(where: { $0.health == .temporarilySilent }) {
            state = .waiting
        } else if diagnostics.contains(where: {
            [.sourceUnreadable, .unknownVersion, .asyncIncompatible].contains($0.health)
        }) {
            state = .needsAttention
        } else if hookInjected {
            state = .hookConfigured
        } else if diagnostics.contains(where: { $0.reasonCode == "awaitingActivity" || $0.reasonCode == "acpIdle" }) {
            state = .waiting
        } else {
            state = configured ? .hookMissing : .notDetected
        }
    }
}
