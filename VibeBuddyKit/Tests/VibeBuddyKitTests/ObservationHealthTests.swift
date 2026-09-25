import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Observation source health wire model")
struct ObservationHealthTests {
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

    @Test("older clients can decode a snapshot without observation fields")
    func oldPayloadDefaultsObservationFields() throws {
        let data = #"{"sessions":[],"serverTime":0}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(snapshot.observationDiagnostics?.isEmpty != false)
    }
}
