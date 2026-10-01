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
        precondition(codex.state == .needsAttention && codex.sources == [.rollout],
                     "An unverified Codex version is observed, but must not be advertised as healthy")
        let grok = AgentIntegrationStatus(configured: true, hookInjected: false, diagnostics: [
            .init(source: .transcript, health: .temporarilySilent, reasonCode: "awaitingActivity")
        ])
        precondition(grok.state == .waiting && grok.sources.isEmpty,
                     "An idle monitor must neither claim live reception nor imply missing integration")
        let unreadable = AgentIntegrationStatus(configured: true, hookInjected: true, diagnostics: [
            .init(source: .transcript, health: .sourceUnreadable, lastObservedAt: now)
        ])
        precondition(unreadable.state == .needsAttention, "A Hook marker must not hide unreadable sources")
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
