import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

private func hook(_ event: String, session: String) -> Data {
    Data(#"{"hook_event_name":"\#(event)","session_id":"\#(session)","cwd":"/x/p"}"#.utf8)
}

@Suite("Attention — the user's choice per session, owned by the daemon")
struct AttentionTests {
    /// A private directory per file: the journal chmods its parent to 0700,
    /// which the shared temp root refuses, and a refused persist is silent.
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vbattention-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
    }

    @Test("a set level shows on the session in every snapshot; nil clears it")
    func setAndClear() async {
        let store = SessionStore()
        await store.ingest(hook("SessionStart", session: "a"), receivedAt: Date())
        #expect(await store.setAttention(sessionID: "a", .muted))
        #expect(await store.snapshot(now: Date()).sessions.first?.attention == .muted)
        #expect(await store.setAttention(sessionID: "a", nil))
        #expect(await store.snapshot(now: Date()).sessions.first?.attention == nil)
    }

    @Test("an unknown session takes no level")
    func unknownSessionRefused() async {
        let store = SessionStore()
        #expect(await store.setAttention(sessionID: "ghost", .followed) == false)
    }

    @Test("a level dies with its session")
    func prunedWithSession() async {
        let url = tempURL()
        let store = SessionStore(attentionURL: url)
        await store.ingest(hook("SessionStart", session: "a"), receivedAt: Date())
        await store.setAttention(sessionID: "a", .followed)
        await store.ingest(hook("SessionEnd", session: "a"), receivedAt: Date())
        let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
        #expect(!text.contains("followed"))
    }

    @Test("a level survives a restart when the journal restores the session")
    func persistsAcrossRestart() async throws {
        let attentionURL = tempURL()
        let journalURL = tempURL()
        let t0 = Date()
        let first = SessionStore(journalURL: journalURL, attentionURL: attentionURL, now: t0)
        await first.ingest(hook("SessionStart", session: "a"), receivedAt: t0)
        await first.ingest(hook("UserPromptSubmit", session: "a"), receivedAt: t0)
        await first.setAttention(sessionID: "a", .muted)

        let second = SessionStore(journalURL: journalURL, attentionURL: attentionURL,
                                  now: t0.addingTimeInterval(5))
        let restored = await second.snapshot(now: t0.addingTimeInterval(5)).sessions
        #expect(restored.first(where: { $0.id == "a" })?.attention == .muted)
    }

    @Test("POST /attention sets, clears, and refuses what it cannot parse")
    func route() async throws {
        let store = SessionStore()
        await store.ingest(hook("SessionStart", session: "a"), receivedAt: Date())
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876)
        try await srv.buildApplication().test(.router) { client in
            func post(_ body: String) async throws -> HTTPResponse.Status {
                try await client.execute(uri: "/attention", method: .post,
                                         headers: [.authorization: "Bearer t0k"],
                                         body: ByteBuffer(string: body)) { $0.status }
            }
            #expect(try await post(#"{"sessionId":"a","attention":"followed"}"#) == .ok)
            #expect(await store.snapshot(now: Date()).sessions.first?.attention == .followed)
            #expect(try await post(#"{"sessionId":"a","attention":null}"#) == .ok)
            #expect(await store.snapshot(now: Date()).sessions.first?.attention == nil)
            #expect(try await post(#"{"sessionId":"a","attention":"loud"}"#) == .badRequest)
            #expect(try await post(#"{"sessionId":"ghost","attention":"muted"}"#) == .notFound)
            try await client.execute(uri: "/attention", method: .post,
                                     body: ByteBuffer(string: #"{"sessionId":"a","attention":"muted"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
