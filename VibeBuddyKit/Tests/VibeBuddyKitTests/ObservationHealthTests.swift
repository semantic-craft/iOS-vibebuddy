import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Observation source health wire model")
struct ObservationHealthTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("source and health raw values are stable")
    func stableRawValues() {
        #expect(ObservationSource.hook.rawValue == "hook")
        #expect(ObservationSource.rollout.rawValue == "rollout")
        #expect(ObservationSource.transcript.rawValue == "transcript")
        #expect(ObservationSource.recovery.rawValue == "recovery")
        #expect(ObservationHealth.healthy.rawValue == "healthy")
        #expect(ObservationHealth.temporarilySilent.rawValue == "temporarilySilent")
        #expect(ObservationHealth.eventsMissing.rawValue == "eventsMissing")
        #expect(ObservationHealth.asyncIncompatible.rawValue == "asyncIncompatible")
        #expect(ObservationHealth.sourceUnreadable.rawValue == "sourceUnreadable")
        #expect(ObservationHealth.notInstalled.rawValue == "notInstalled")
        #expect(ObservationHealth.unknownVersion.rawValue == "unknownVersion")
    }

    @Test("mixed observation sources round-trip on a session")
    func mixedSourcesRoundTrip() throws {
        let observations = [
            ObservationEvidence(source: .hook, lastObservedAt: t0, health: .healthy),
            ObservationEvidence(source: .transcript, lastObservedAt: t0.addingTimeInterval(2), health: .healthy),
        ]
        let session = AgentSession(
            id: "s", agent: .claudeCode, project: "demo", status: .working,
            observations: observations, statusSince: t0, updatedAt: t0)

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: encoded)

        #expect(decoded.observations == observations)
        #expect(decoded.observationDescription == "Hook + Transcript · Healthy")
    }

    @Test("older clients can decode a snapshot without observation fields")
    func oldPayloadDefaultsObservationFields() throws {
        let data = #"{"sessions":[],"serverTime":0}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(snapshot.observationDiagnostics?.isEmpty != false)
    }

    @Test("Mac and iOS can share one human-readable health explanation")
    func sharedHumanReadableExplanation() {
        #expect(ObservationHealth.asyncIncompatible.explanation(for: .hook)
                == "Codex ignores asynchronous command hooks in this version.")
        #expect(ObservationHealth.sourceUnreadable.explanation(for: .rollout)
                == "The rollout stream cannot be read.")
        #expect(ObservationHealth.temporarilySilent.displayName == "Temporarily silent")
    }
}
