import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("OH-1 active snapshot contract")
struct ObservationDiagnosticCompatibilityTests {
    @Test("old phone model decodes a complete snapshot with new and unknown reasons")
    func oldPhoneDecodesSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let rows = [
            ObservationSourceDiagnostic(source: .hook, health: .temporarilySilent,
                configuredCoverage: ObservationEventCoverage.allCases, reasonCode: "awaitingActivity"),
            ObservationSourceDiagnostic(source: .statusline, health: .notInstalled,
                reasonCode: "optionalSourceNotConfigured"),
            ObservationSourceDiagnostic(source: .transcript, health: .eventsMissing,
                reasonCode: "futureReason", sourceVersion: "futureVersion")
        ]
        var snapshot = Snapshot(sessions: [], serverTime: now, sourceID: "test-mac",
            observationDiagnostics: [.init(agent: .claudeCode, sources: rows)],
            providerQuota: [], recentDirectories: ["/test"], dispatchAgents: [.codex])
        for status in [SessionStatus.working, .needsResponse, .done] {
            var reducerSession = AgentSession(id: status.rawValue, agent: .claudeCode, project: "test", status: status,
                statusSince: now, updatedAt: now)
            reducerSession.observations = [.init(source: .hook, lastObservedAt: now, health: .healthy)]
            snapshot.sessions.append(reducerSession)
        }
        let data = try JSONEncoder().encode(snapshot)
        let old = try JSONDecoder().decode(OldSnapshot.self, from: data)
        #expect(old.sessions == snapshot.sessions)
        #expect(old.serverTime == snapshot.serverTime)
        #expect(old.sourceID == snapshot.sourceID)
        #expect(old.recentDirectories == snapshot.recentDirectories)
        #expect(old.dispatchAgents == snapshot.dispatchAgents)
        #expect(old.providerQuota == snapshot.providerQuota)
        #expect(old.observationDiagnostics?.first?.sources.map(\.health) == snapshot.observationDiagnostics?.first?.sources.map(\.health))
        #expect(try JSONDecoder().decode(Snapshot.self, from: data) == snapshot)
        let oldData = try JSONEncoder().encode(old)
        let newFromOld = try JSONDecoder().decode(Snapshot.self, from: oldData)
        #expect(newFromOld.observationDiagnostics?.first?.sources.allSatisfy { $0.reasonCode == nil && $0.sourceVersion == nil } == true)
    }
}

// Stored properties copied from origin/main ece1e72, before OH-1. The other
// model types are unchanged by OH-1. This exercises the complete snapshot, not
// a permissive dictionary or the new diagnostic decoder disguised as an old one.
private struct OldSnapshot: Codable {
    var sourceID: String?
    var sessions: [AgentSession]
    var serverTime: Date
    var observationDiagnostics: [OldAgentDiagnostic]?
    var providerQuota: [ProviderQuota]?
    var recentDirectories: [String]?
    var dispatchAgents: [AgentKind]?
}
private struct OldAgentDiagnostic: Codable {
    let agent: AgentKind
    var sources: [OldSourceDiagnostic]
}
private struct OldSourceDiagnostic: Codable {
    let source: ObservationSource
    var health: ObservationHealth
    var lastObservedAt: Date?
    var configuredCoverage: [ObservationEventCoverage]
    var observedCoverage: [ObservationEventCoverage]
}
