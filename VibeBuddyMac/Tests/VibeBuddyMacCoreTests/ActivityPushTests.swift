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

    @Test("an alert push names its session outside aps, escaped, and can be silent")
    func alertPayloadCarriesSession() {
        let payload = APNsPusher.alertPayload(title: "p needs \"you\"", body: "line\nbreak",
                                              sound: "agent_done.caf", sessionID: "claude/a\"b")
        #expect(payload == #"{"aps":{"alert":{"title":"p needs \"you\"","body":"line break"},"sound":"agent_done.caf","thread-id":"claude/a\"b"},"sessionId":"claude/a\"b"}"#)
        let silent = APNsPusher.alertPayload(title: "t", body: "b", sound: "", sessionID: nil)
        #expect(silent == #"{"aps":{"alert":{"title":"t","body":"b"}}}"#)
    }

    @Test("an approval push carries category, time-sensitive interruption, and the approval id")
    func alertPayloadActionableTimeSensitive() {
        let payload = APNsPusher.alertPayload(
            title: "p needs permission", body: "rm -rf x", sound: "needs_approval.caf",
            sessionID: "s1", category: NotificationCategoryID.approval.rawValue,
            timeSensitive: true, approvalId: "ap-9")
        #expect(payload.contains(#""category":"approval""#))
        #expect(payload.contains(#""interruption-level":"time-sensitive""#))
        #expect(payload.contains(#""approvalId":"ap-9""#))
        #expect(payload.contains(#""sessionId":"s1""#))
        let quiet = APNsPusher.alertPayload(
            title: "t", body: "b", sound: "agent_done.caf", sessionID: "s",
            category: nil, timeSensitive: false, approvalId: nil)
        #expect(!quiet.contains("category"))
        #expect(!quiet.contains("interruption-level"))
        #expect(!quiet.contains("approvalId"))
    }

    @Test("a localized push carries the phone's string keys next to the English copy")
    func alertPayloadLocalized() {
        let free = APNsPusher.alertPayload(
            title: "p needs permission", body: "rm -rf \"x\"", sound: "", sessionID: "s",
            localized: PushLocalization(titleKey: "%@ needs permission", titleArgs: ["p"], bodyKey: nil))
        #expect(free == #"{"aps":{"alert":{"title":"p needs permission","body":"rm -rf \"x\"","title-loc-key":"%@ needs permission","title-loc-args":["p"]},"thread-id":"s"},"sessionId":"s"}"#)
        let fixed = APNsPusher.alertPayload(
            title: "p is done", body: "Task complete", sound: "", sessionID: "s",
            localized: PushLocalization(titleKey: "%@ is done", titleArgs: ["p"], bodyKey: "Task complete"))
        #expect(fixed.contains(#""loc-key":"Task complete""#))
    }

    @Test("push copy says what the phone's own banner says")
    func pushCopyMirrorsPhone() {
        var s = AgentSession(id: "s", agent: .claudeCode, project: "proj", status: .needsResponse,
                             statusSince: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        s.summary = "Which file?"
        let ask = PushCopy.copy(for: .needsAnswer, session: s)
        #expect(ask == PushCopy(title: "proj needs you", body: "Which file?",
                                titleKey: "%@ needs you", titleArgs: ["proj"], bodyKey: nil))
        s.summary = nil
        let done = PushCopy.copy(for: .agentDone, session: s)
        #expect(done == PushCopy(title: "proj is done", body: "Task complete",
                                 titleKey: "%@ is done", titleArgs: ["proj"], bodyKey: "Task complete"))
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
