import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("VibeBuddyServer — routes")
struct VibeBuddyServerTests {

    private func server(token: String = "t0k") -> VibeBuddyServer {
        VibeBuddyServer(store: SessionStore(), token: token)
    }

    @Test("health is open and returns ok")
    func health() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("snapshot without a token is 401")
    func snapshotUnauthorized() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/snapshot", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("snapshot with the wrong token is 401")
    func snapshotWrongToken() async throws {
        try await server(token: "right").buildApplication().test(.router) { client in
            try await client.execute(uri: "/snapshot", method: .get,
                                     headers: [.authorization: "Bearer wrong"]) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("hook intake then snapshot reflects the classified session")
    func hookThenSnapshot() async throws {
        let start = #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#
        let notif = #"{"hook_event_name":"Notification","session_id":"s","message":"needs your permission"}"#

        try await server(token: "t0k").buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post, body: ByteBuffer(string: start)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/hook", method: .post, body: ByteBuffer(string: notif)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/snapshot", method: .get,
                                     headers: [.authorization: "Bearer t0k"]) { res in
                #expect(res.status == .ok)
                let snap = try JSONDecoder().decode(Snapshot.self, from: Data(buffer: res.body))
                #expect(snap.sessions.count == 1)
                #expect(snap.sessions.first?.status == .needsResponse)
                #expect(snap.sessions.first?.waitKind == .permission)
                #expect(snap.sessions.first?.project == "demo")
            }
        }
    }
}
