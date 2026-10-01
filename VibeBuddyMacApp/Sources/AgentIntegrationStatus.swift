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

    init(configured: Bool, hookInjected: Bool, diagnostics: [ObservationSourceDiagnostic],
         sessionEvidence: [ObservationEvidence] = [], now: Date = Date()) {
        var diagnostics = diagnostics
        // The aggregate Grok diagnostic currently lists Hook and transcript
        // only. Hosted ACP is recorded on the session itself. Supplement missing
        // sources, but never override an explicit diagnostic with older evidence.
        let diagnosed = Set(diagnostics.map(\.source))
        let evidence = Dictionary(grouping: sessionEvidence.filter {
            !diagnosed.contains($0.source) && $0.source != .recovery && $0.source != .gateway
        }, by: \.source)
        for (source, entries) in evidence {
            guard let latest = entries.max(by: { $0.lastObservedAt < $1.lastObservedAt }) else { continue }
            let health: ObservationHealth = latest.health == .healthy && now.timeIntervalSince(latest.lastObservedAt) > 600
                ? .temporarilySilent : latest.health
            diagnostics.append(.init(source: source, health: health, lastObservedAt: latest.lastObservedAt))
        }
        let observed = diagnostics.filter { $0.lastObservedAt != nil }
        let faults = diagnostics.filter {
            [.sourceUnreadable, .unknownVersion, .asyncIncompatible].contains($0.health)
        }
        sources = diagnostics.filter { $0.lastObservedAt != nil || faults.contains($0) }.map(\.source).sorted()
        if faults.contains(where: { $0.source != .cloud }) {
            state = .needsAttention
        } else if observed.contains(where: { $0.health == .healthy }) {
            // A separately configured, optional cloud source cannot invalidate
            // healthy local observation. Its own diagnostics still show failure.
            state = .receiving
        } else if !faults.isEmpty {
            state = .needsAttention
        } else if observed.contains(where: { $0.health == .temporarilySilent }) || diagnostics.contains(where: {
            $0.reasonCode == "awaitingActivity" || $0.reasonCode == "acpIdle"
        }) {
            state = .waiting
        } else if hookInjected {
            state = .hookConfigured
        } else {
            state = configured ? .hookMissing : .notDetected
        }
    }
}
