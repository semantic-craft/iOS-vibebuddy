import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Wire model coding")
struct WireCodingTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
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
            read: { stored[$0].map(PushDeviceIdentity.Lookup.found) ?? .missing },
            write: { stored[$1] = $0; return true }, mint: mint)
        let second = PushDeviceIdentity.current(
            read: { stored[$0].map(PushDeviceIdentity.Lookup.found) ?? .missing },
            write: { stored[$1] = $0; return true }, mint: mint)
        #expect(first == "id-1")
        #expect(second == first)
        #expect(minted == 1)
        // A blank stored value counts as none — it must not become the identity.
        stored[PushDeviceIdentity.keychainKey] = ""
        #expect(PushDeviceIdentity.current(
            read: { stored[$0].map(PushDeviceIdentity.Lookup.found) ?? .missing },
            write: { stored[$1] = $0; return true }, mint: mint) == nil)
    }

    @Test("an unavailable identity store never advertises an unpersisted device id")
    func pushIdentityRequiresPersistence() {
        let identity = PushDeviceIdentity.current(read: { _ in .missing }, write: { _, _ in false }, mint: { "temporary" })
        #expect(identity == nil)
    }

    @Test("temporary identity read failure never invokes a replacing write")
    func pushIdentityReadFailureNeverWrites() {
        var writes = 0
        let identity = PushDeviceIdentity.current(read: { _ in .unavailable },
            write: { _, _ in writes += 1; return true }, mint: { "replacement" })
        #expect(identity == nil)
        #expect(writes == 0)
    }

    @Test("competing identity creation reads the persisted winner")
    func pushIdentityCreationRace() {
        var stored: String?
        let identity = PushDeviceIdentity.current(
            read: { _ in stored.map(PushDeviceIdentity.Lookup.found) ?? .missing },
            write: { _, _ in stored = "other-caller"; return false }, mint: { "ours" })
        #expect(identity == "other-caller")
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
}
