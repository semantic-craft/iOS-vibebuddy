import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Token consumption wire")
struct TokenConsumptionWireTests {
    @Test("old snapshot JSON without tokenConsumption still decodes")
    func missingFieldIsNil() throws {
        let json = """
        {"sessions":[],"serverTime":1700000000,"sourceID":"mac-1"}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: json)
        #expect(snap.tokenConsumption == nil)
        #expect(snap.sessions.isEmpty)
    }

    @Test("tokenConsumption round-trips on Snapshot")
    func roundTrip() throws {
        let consumption = TokenConsumptionSnapshot.demo(now: Date(timeIntervalSince1970: 1_700_000_000))
        let source = Snapshot(sessions: [], serverTime: Date(timeIntervalSince1970: 1_700_000_000),
                              sourceID: "mac-1", tokenConsumption: consumption)
        let back = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(source))
        #expect(back.tokenConsumption == consumption)
        #expect(TokenConsumptionSnapshot.formatTokens(1_200_000) == "1.2M")
        #expect(TokenConsumptionSnapshot.formatUSD(4.2) == "≈ $4.20")
    }
}
