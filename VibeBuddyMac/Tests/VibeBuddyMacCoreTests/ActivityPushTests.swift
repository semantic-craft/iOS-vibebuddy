import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Live Activity push (dynamic-island/02)")
struct ActivityPushTests {

    // MARK: ActivityTokens

    @Test("register / all / remove")
    func tokenStore() async {
        let store = ActivityTokens()
        await store.register("aabb")
        await store.register("aabb")   // idempotent
        await store.register("")        // ignored
        #expect(await store.all() == ["aabb"])
        await store.remove("aabb")
        #expect(await store.all().isEmpty)
    }

    // MARK: payload shape (liveactivity content-state)

    @Test("payload carries an update event with the counts")
    func payloadCounts() {
        let p = APNsPusher.activityPayload(summary: TaskPresentationSummary(
                                               idle: 0, thinking: 1, completeUnread: 0,
                                               requiresInput: 2, error: 0),
                                           topProject: nil, topSessionId: nil, timestamp: 1700)
        #expect(p.contains(#""event":"update""#))
        #expect(p.contains(#""timestamp":1700"#))
        #expect(p.contains(#""summary":{"idle":0,"thinking":1,"completeUnread":0,"requiresInput":2,"error":0}"#))
        #expect(!p.contains("topProject"))   // omitted when nil
    }

    @Test("optional strings are included and escaped when present")
    func payloadOptionals() {
        let p = APNsPusher.activityPayload(summary: TaskPresentationSummary(completeUnread: 1),
                                           topProject: #"my "proj""#, topSessionId: "s1", timestamp: 1)
        #expect(p.contains(#""topProject":"my \"proj\"""#))
        #expect(p.contains(#""topSessionId":"s1""#))
    }

    // MARK: /activity route

    @Test("/activity without a token is 401")
    func activityUnauthorized() async throws {
        let srv = VibeBuddyServer(store: SessionStore(), token: "t0k")
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/activity", method: .post,
                                     body: ByteBuffer(string: #"{"token":"abc"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("/activity registers the activity push token")
    func activityRegisters() async throws {
        let tokens = ActivityTokens()
        let srv = VibeBuddyServer(store: SessionStore(), token: "t0k", activityTokens: tokens)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/activity", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"token":"deadbeef"}"#)) { res in
                #expect(res.status == .ok)
            }
        }
        #expect(await tokens.all() == ["deadbeef"])
    }
}
