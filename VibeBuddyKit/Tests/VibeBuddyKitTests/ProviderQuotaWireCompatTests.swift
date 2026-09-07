import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("ProviderQuota wire forward-compat (#111)")
struct ProviderQuotaWireCompatTests {

    /// App Store v1.3 vocabulary: no `cursor`. Used to prove a HEAD payload
    /// with `cursor` can still be read when unknown providers are skipped.
    private enum OldAccountUsageProvider: String, Codable {
        case codex, claude, grok
    }

    private struct OldProviderQuota: Codable {
        var provider: OldAccountUsageProvider
        var weeklyRemainingPercent: Int?
        var unavailableReason: String?
    }

    private func sampleSnapshot(includingCursor: Bool) -> Snapshot {
        var rows: [ProviderQuota] = [
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 70),
            ProviderQuota(provider: .claude, weeklyRemainingPercent: 40),
            ProviderQuota(provider: .grok, weeklyRemainingPercent: 55),
        ]
        if includingCursor {
            rows.append(ProviderQuota(provider: .cursor, weeklyRemainingPercent: 60))
        }
        return Snapshot(
            sessions: [],
            serverTime: Date(timeIntervalSince1970: 1_700_000_000),
            sourceID: "mac-1",
            providerQuota: rows
        )
    }

    @Test("unknown provider string in providerQuota does not kill Snapshot decode")
    func unknownProviderSkipped() throws {
        let json = """
        {"sessions":[],"serverTime":1700000000,
         "providerQuota":[
           {"provider":"codex","weeklyRemainingPercent":70},
           {"provider":"futureProvider","weeklyRemainingPercent":12},
           {"provider":"claude","weeklyRemainingPercent":40}
         ]}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: json)
        #expect(snap.providerQuota?.map(\.provider) == [.codex, .claude])
        #expect(snap.sessions.isEmpty)
    }

    @Test("new clients still keep Cursor when present")
    func newClientKeepsCursor() throws {
        let snap = sampleSnapshot(includingCursor: true)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(Snapshot.self, from: data)
        #expect(back.providerQuota?.map(\.provider).contains(.cursor) == true)
        #expect(back.providerQuota?.first { $0.provider == .cursor }?.weeklyRemainingPercent == 60)

        let eventData = try JSONEncoder().encode(ServerEvent.snapshot(snap))
        guard case .snapshot(let fromEvent) = try JSONDecoder().decode(ServerEvent.self, from: eventData) else {
            Issue.record("expected snapshot event")
            return
        }
        #expect(fromEvent.providerQuota?.map(\.provider).contains(.cursor) == true)
    }

    @Test("old vocabulary can decode HEAD Snapshot that includes cursor by skipping the row")
    func oldVocabSkipsCursorRow() throws {
        // Simulate the lossy array path with the pre-Cursor enum: decode each
        // row, skip failures (cursor), keep known providers.
        let head = sampleSnapshot(includingCursor: true)
        let data = try JSONEncoder().encode(head)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rows = obj["providerQuota"] as! [[String: Any]]
        var kept: [OldProviderQuota] = []
        for row in rows {
            let rowData = try JSONSerialization.data(withJSONObject: row)
            if let decoded = try? JSONDecoder().decode(OldProviderQuota.self, from: rowData) {
                kept.append(decoded)
            }
        }
        #expect(kept.map(\.provider) == [.codex, .claude, .grok])
        #expect(!kept.map(\.provider.rawValue).contains("cursor"))

        // Production Snapshot decoder keeps known providers (including cursor)
        // and drops a not-yet-known string without failing the frame.
        let withFuture = """
        {"sessions":[],"serverTime":1700000000,
         "providerQuota":[
           {"provider":"codex","weeklyRemainingPercent":70},
           {"provider":"cursor","weeklyRemainingPercent":60},
           {"provider":"notYetKnown","weeklyRemainingPercent":1}
         ]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Snapshot.self, from: withFuture)
        #expect(decoded.providerQuota?.map(\.provider) == [.codex, .cursor])
    }

    @Test("ServerEvent.snapshot round-trip keeps known rows after unknown skip")
    func serverEventSurvivesUnknownProvider() throws {
        let snapJSON = """
        {"sessions":[],"serverTime":1700000000,
         "providerQuota":[
           {"provider":"codex","weeklyRemainingPercent":10},
           {"provider":"brandNewProvider","unavailableReason":"x"}
         ]}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: snapJSON)
        #expect(snap.providerQuota?.map(\.provider) == [.codex])
        let event = ServerEvent.snapshot(snap)
        let back = try JSONDecoder().decode(ServerEvent.self, from: JSONEncoder().encode(event))
        #expect(back == event)
    }
}
