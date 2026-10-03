import Foundation
import VibeBuddyKit

// Compile with the app's AgentIntegrationStatus.swift and VibeBuddyKit.
// An optional JSON path replays snapshot.observationDiagnostics from a real Mac.
@main
struct AgentIntegrationRegression {
    static func main() throws {
        let now = Date()
        let cursor = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [
            .init(source: .hook, health: .eventsMissing, reasonCode: "configurationIncomplete"),
            .init(source: .transcript, health: .healthy, lastObservedAt: now),
            .init(source: .cloud, health: .notInstalled, reasonCode: "optionalSourceNotConfigured")
        ])
        precondition(cursor.state == .receiving && cursor.sources == [.transcript],
                     "A live Cursor transcript must count even without Hooks or a cloud key")
        let codex = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [
            .init(source: .rollout, health: .unknownVersion, lastObservedAt: now, reasonCode: "versionUnverified")
        ])
        precondition(codex.state == .versionUnverified && codex.sources == [.rollout],
                     "An unverified Codex version is observed, but must not be advertised as healthy")
        let grok = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [
            .init(source: .transcript, health: .temporarilySilent, reasonCode: "awaitingActivity")
        ])
        precondition(grok.state == .waiting && grok.sources.isEmpty,
                     "An idle monitor must neither claim live reception nor imply missing integration")
        let hostedGrok = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [
            .init(source: .transcript, health: .temporarilySilent, reasonCode: "awaitingActivity")
        ], sessionEvidence: [.init(source: .acp, lastObservedAt: now, health: .healthy)], now: now)
        precondition(hostedGrok.state == .receiving && hostedGrok.sources == [.acp],
                     "Hosted Grok ACP must count even when aggregate diagnostics omit that source")
        let staleGrok = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [],
            sessionEvidence: [.init(source: .acp, lastObservedAt: now.addingTimeInterval(-601), health: .healthy)], now: now)
        precondition(staleGrok.state == .waiting, "Old ACP evidence must not claim current reception")
        let unreadable = AgentIntegrationStatus(configured: true, hookInjected: true, diagnostics: [
            .init(source: .transcript, health: .sourceUnreadable, lastObservedAt: now)
        ])
        precondition(unreadable.state == .sourceUnreadable, "A Hook marker must not hide unreadable sources")
        let mixedCodex = AgentIntegrationStatus(configured: true, hookInjected: true, diagnostics: [
            .init(source: .appserver, health: .healthy, lastObservedAt: now),
            .init(source: .rollout, health: .unknownVersion, reasonCode: "versionUnverified")
        ])
        precondition(mixedCodex.state == .versionUnverified && mixedCodex.sources.contains(.rollout),
                     "A healthy sibling must not hide an unverified rollout or omit its source name")
        let corruptCodex = AgentIntegrationStatus(configured: true, hookInjected: true, diagnostics: [
            .init(source: .rollout, health: .unknownVersion, reasonCode: "invalidSourceData")
        ])
        precondition(corruptCodex.state == .needsAttention, "Invalid data is a fault, not an unverified version")
        let brokenSibling = AgentIntegrationStatus(configured: true, hookInjected: true, diagnostics: [
            .init(source: .rollout, health: .unknownVersion, reasonCode: "versionUnverified"),
            .init(source: .hook, health: .sourceUnreadable)
        ])
        precondition(brokenSibling.state == .sourceUnreadable, "An unverified version must not hide a read failure")
        let wiredIdle = AgentIntegrationStatus(configured: true, hookInjected: true, diagnostics: [
            .init(source: .transcript, health: .temporarilySilent, reasonCode: "awaitingActivity")
        ])
        precondition(wiredIdle.state == .waiting, "Hook installation must remain separate from activity")
        let optionalCloudFailure = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [
            .init(source: .transcript, health: .healthy, lastObservedAt: now),
            .init(source: .cloud, health: .sourceUnreadable)
        ])
        precondition(optionalCloudFailure.state == .receiving, "An optional cloud failure must not obscure healthy local reception")
        if let path = CommandLine.arguments.dropFirst().first {
            let diagnostics = try JSONDecoder().decode([AgentObservationDiagnostic].self,
                                                       from: Data(contentsOf: URL(fileURLWithPath: path)))
            for agent in diagnostics {
                let result = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: agent.sources)
                if agent.agent == .cursor { precondition(result.state == .receiving) }
                print("\(agent.agent.rawValue): \(result.state); sources: \(result.sources.map(\.rawValue))")
            }
        }
        print("Agent integration regressions passed")
    }
}
