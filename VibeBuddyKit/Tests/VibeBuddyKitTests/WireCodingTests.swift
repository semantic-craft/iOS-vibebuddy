import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Wire model coding")
struct WireCodingTests {

    private func sampleSession(
        id: String = "abc123",
        agent: AgentKind = .claudeCode,
        status: SessionStatus = .working,
        waitKind: WaitKind? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, agent: agent, project: "vibebuddy", branch: "main",
            model: "claude-opus-4-8", status: status, waitKind: waitKind,
            summary: "wrote section 2", tokens: 12345,
            statusSince: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_060)
        )
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // 1. Construction / happy path
    @Test("AgentSession round-trips")
    func sessionRoundTrip() throws {
        let s = sampleSession(status: .needsResponse, waitKind: .permission)
        #expect(try roundTrip(s) == s)
    }

    // 2. Aggregate round-trip
    @Test("Snapshot round-trips")
    func snapshotRoundTrip() throws {
        let snap = Snapshot(
            sessions: [sampleSession(), sampleSession(id: "def456", status: .done)],
            serverTime: Date(timeIntervalSince1970: 1_700_000_100)
        )
        #expect(try roundTrip(snap) == snap)
    }

    // 3. Every ServerEvent case
    @Test("ServerEvent round-trips for every case")
    func serverEventRoundTrip() throws {
        let events: [ServerEvent] = [
            .snapshot(Snapshot(sessions: [sampleSession()],
                               serverTime: Date(timeIntervalSince1970: 1))),
            .sessionUpdated(sampleSession(status: .needsResponse, waitKind: .question)),
            .sessionRemoved(id: "abc123"),
        ]
        for e in events { #expect(try roundTrip(e) == e) }
    }

    // 4. Pairing payload
    @Test("PairingPayload round-trips")
    func pairingRoundTrip() throws {
        let p = PairingPayload(host: "192.168.1.20", port: 9876, token: "s3cr3t")
        #expect(try roundTrip(p) == p)
    }

    // 5. Wire-format stability — rawValues are the documented strings
    @Test("status & agent raw values are stable wire strings")
    func rawValuesStable() {
        #expect(SessionStatus.needsResponse.rawValue == "needsResponse")
        #expect(SessionStatus.working.rawValue == "working")
        #expect(SessionStatus.done.rawValue == "done")
        #expect(WaitKind.permission.rawValue == "permission")
        #expect(WaitKind.question.rawValue == "question")
        #expect(AgentKind.claudeCode.rawValue == "claudeCode")
        #expect(AgentKind.codex.rawValue == "codex")
    }

    // 6. Decodes a known external JSON payload (pins the contract)
    @Test("decodes a known JSON payload")
    func decodesKnownJSON() throws {
        let json = """
        {"id":"x","agent":"codex","project":"p","branch":null,"model":null,
         "status":"needsResponse","waitKind":"permission","summary":null,"tokens":null,
         "statusSince":0,"updatedAt":0}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AgentSession.self, from: json)
        #expect(s.agent == .codex)
        #expect(s.status == .needsResponse)
        #expect(s.waitKind == .permission)
        #expect(s.branch == nil)
        #expect(s.tokens == nil)
    }

    // 7. Behavior — attention ordering for the dashboard
    @Test("needsResponse sorts before working before done")
    func attentionRank() {
        #expect(SessionStatus.needsResponse.attentionRank < SessionStatus.working.attentionRank)
        #expect(SessionStatus.working.attentionRank < SessionStatus.done.attentionRank)
    }
}
