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
        let p = PairingPayload(host: "192.168.1.20", port: 9876,
                               token: "s3cr3t", macName: "Xianwei's Mac")
        #expect(try roundTrip(p) == p)
    }

    @Test("DeviceRegistrationPayload round-trips")
    func deviceRegistrationRoundTrip() throws {
        let p = DeviceRegistrationPayload(token: "apns-token", name: "Hermes",
                                          model: "iPhone", systemVersion: "iOS 26.0")
        #expect(try roundTrip(p) == p)
        var withPrefs = p
        withPrefs.categories = NotificationCategoryPrefs(enabled: [.needsApproval, .agentDone])
        #expect(try roundTrip(withPrefs) == withPrefs)
        // The attention level rides on the session wire model and is optional.
        let followed = AgentSession(id: "f", agent: .codex, project: "p", status: .done,
                                    attention: .followed, attentionOverride: .followed,
                                    statusSince: .init(timeIntervalSince1970: 0),
                                    updatedAt: .init(timeIntervalSince1970: 0))
        #expect(try roundTrip(followed).effectiveAttention == .followed)
        #expect(try roundTrip(followed).attentionOverride == .followed)
        // A payload from a build before the switches existed still decodes.
        let legacy = try JSONDecoder().decode(DeviceRegistrationPayload.self,
                                              from: Data(#"{"token":"t","playSound":true}"#.utf8))
        #expect(legacy.categories == nil)
        #expect(legacy.deviceID == nil)
        // The stable identity rides along and round-trips.
        var identified = p
        identified.deviceID = "3E1D-hermes"
        #expect(try roundTrip(identified).deviceID == "3E1D-hermes")
    }

    @Test("PushDeviceIdentity mints once and then reads back the same value")
    func pushDeviceIdentityIsStable() {
        var stored: [String: String] = [:]
        var minted = 0
        let mint = { minted += 1; return "id-\(minted)" }
        let first = PushDeviceIdentity.current(
            read: { stored[$0] }, write: { stored[$1] = $0 }, mint: mint)
        let second = PushDeviceIdentity.current(
            read: { stored[$0] }, write: { stored[$1] = $0 }, mint: mint)
        #expect(first == "id-1")
        #expect(second == first)
        #expect(minted == 1)
        // A blank stored value counts as none — it must not become the identity.
        stored[PushDeviceIdentity.keychainKey] = ""
        #expect(PushDeviceIdentity.current(
            read: { stored[$0] }, write: { stored[$1] = $0 }, mint: mint) == "id-2")
    }

    // 5. Wire-format stability — rawValues are the documented strings
    @Test("status & agent raw values are stable wire strings")
    func rawValuesStable() {
        #expect(SessionStatus.needsResponse.rawValue == "needsResponse")
        #expect(SessionStatus.working.rawValue == "working")
        #expect(SessionStatus.done.rawValue == "done")
        #expect(TaskPresentationState.completeUnread.rawValue == "completeUnread")
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
         "hasUnreadCompletion":false,
         "statusSince":0,"updatedAt":0}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AgentSession.self, from: json)
        #expect(s.agent == .codex)
        #expect(s.status == .needsResponse)
        #expect(s.waitKind == .permission)
        #expect(s.branch == nil)
        #expect(s.tokens == nil)
        #expect(!s.hasUnreadCompletion)
    }

    // 7. Behavior — attention ordering for the dashboard
    @Test("needsResponse sorts before working before done")
    func attentionRank() {
        #expect(SessionStatus.needsResponse.attentionRank < SessionStatus.working.attentionRank)
        #expect(SessionStatus.working.attentionRank < SessionStatus.done.attentionRank)
    }

    // 8. PendingApproval round-trip
    @Test("AgentSession round-trips a pendingApproval")
    func pendingApprovalRoundTrips() throws {
        var s = sampleSession(status: .needsResponse, waitKind: .permission)
        s.pendingApproval = PendingApproval(id: "ap1", tool: "Bash", commandPreview: "rm -rf build")
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AgentSession.self, from: data)
        #expect(back.pendingApproval == s.pendingApproval)
        #expect(back.pendingApproval?.commandPreview == "rm -rf build")
    }

    @Test("pendingApproval defaults to nil and stays absent when unset")
    func pendingApprovalDefaultsNil() {
        let s = sampleSession(status: .working)
        #expect(s.pendingApproval == nil)
    }

    @Test("completion unread is carried on the authoritative session wire model")
    func completionUnreadRoundTrips() throws {
        var session = sampleSession(status: .done)
        session.hasUnreadCompletion = true
        let decoded = try roundTrip(session)
        #expect(decoded.hasUnreadCompletion)
        #expect(decoded.presentationState == .completeUnread)
    }

    @Test("AgentSession round-trips a pendingQuestion with options")
    func pendingQuestionRoundTrips() throws {
        var s = sampleSession(status: .needsResponse, waitKind: .question)
        s.pendingQuestion = PendingQuestion(
            id: "q1",
            prompt: "Which branch should I use?",
            options: [
                QuestionOption(id: "main", label: "main", value: "main", description: "Use the current branch"),
                QuestionOption(id: "new", label: "new branch", value: "create a new branch"),
            ])
        let back = try JSONDecoder().decode(AgentSession.self, from: try JSONEncoder().encode(s))
        #expect(back.pendingQuestion == s.pendingQuestion)
        #expect(back.pendingQuestion?.options.map(\.value) == ["main", "create a new branch"])
    }

    @Test("AgentSession round-trips a terminalRef")
    func terminalRefRoundTrips() throws {
        var s = sampleSession(status: .working)
        s.terminalRef = TerminalRef(termProgram: "ghostty", tty: "ttys003", tmux: "/tmp/tmux-501/default,1,0", tmuxPane: "%3")
        let back = try JSONDecoder().decode(AgentSession.self, from: try JSONEncoder().encode(s))
        #expect(back.terminalRef == s.terminalRef)
        #expect(back.terminalRef?.tmuxPane == "%3")
    }
}
