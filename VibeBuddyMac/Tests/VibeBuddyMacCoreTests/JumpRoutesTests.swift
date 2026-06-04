import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Jump routes")
struct JumpRoutesTests {
    @Test("/terminal stores the ref; /jump (with token) invokes the jumper")
    func storeThenJump() async throws {
        final class Box: @unchecked Sendable { var jumped: [String] = [] }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k",
                                     onJump: { box.jumped.append($0.tmuxPane ?? "") })
        try await server.buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
                body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty","tmux":"/tmp/x,1,0","tmux_pane":"%5"}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(box.jumped == ["%5"])
        }
    }

    @Test("/jump without a token is 401")
    func jumpUnauthorized() async throws {
        try await VibeBuddyServer(store: SessionStore(), token: "t0k").buildApplication().test(.router) { client in
            try await client.execute(uri: "/jump", method: .post,
                body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { res in #expect(res.status == .unauthorized) }
        }
    }
}
