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
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
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

    private func outcome(_ body: ByteBuffer) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: Data(buffer: body)))?["outcome"]
    }

    @Test("a supported terminal reports outcome=focused")
    func reportsFocused() async throws {
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k", onJump: { _ in })
        try await server.buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty"}"#)) { _ in }
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { res in
                #expect(res.status == .ok)
                #expect(self.outcome(res.body) == "focused")
            }
        }
    }

    @Test("an unknown terminal reports outcome=unsupported and does not jump")
    func reportsUnsupported() async throws {
        final class Box: @unchecked Sendable { var jumped = 0 }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k", onJump: { _ in box.jumped += 1 })
        try await server.buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"session_id":"s","term_program":"warp"}"#)) { _ in }
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { res in
                #expect(self.outcome(res.body) == "unsupported")
            }
            #expect(box.jumped == 0)
        }
    }

    @Test("a session with no terminal ref reports outcome=noTerminal")
    func reportsNoTerminal() async throws {
        try await VibeBuddyServer(store: SessionStore(), token: "t0k", onJump: { _ in }).buildApplication().test(.router) { client in
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"ghost"}"#)) { res in
                #expect(self.outcome(res.body) == "noTerminal")
            }
        }
    }
}
