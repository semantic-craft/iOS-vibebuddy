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
                                     onJump: { box.jumped.append($0.tmuxPane ?? ""); return .focused })
        try await server.buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            #expect(await store.snapshot(now: .now).sessions.first?.hasUnreadCompletion == true)
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
            #expect(await store.snapshot(now: .now).sessions.first?.hasUnreadCompletion == false)
        }
    }

    @Test("/terminal decodes the full ref, empty strings included, as nil")
    func storesRichRef() async throws {
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k", onJump: { _ in .focused })
        try await server.buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: """
                {"session_id":"s","term_program":"ghostty","tty":"ttys003","tmux":"",\
                "iterm_session_id":"","wezterm_pane":"4","kitty_window_id":"9",\
                "kitty_listen_on":"unix:/tmp/k","ghostty_terminal_id":"7",\
                "host_bundle_id":"com.mitchellh.ghostty","host_pid":4242,"cwd":"/x/p"}
                """)) { _ in }
            let ref = try #require(await store.terminalRef(for: "s"))
            #expect(ref.termProgram == "ghostty")
            #expect(ref.tty == "ttys003")
            #expect(ref.tmux == nil)
            #expect(ref.itermSessionId == nil)
            #expect(ref.weztermPane == "4")
            #expect(ref.kittyWindowId == "9")
            #expect(ref.kittyListenOn == "unix:/tmp/k")
            #expect(ref.ghosttyTerminalId == "7")
            #expect(ref.hostBundleId == "com.mitchellh.ghostty")
            #expect(ref.hostPid == 4242)
            #expect(ref.cwd == "/x/p")
            #expect(ref.hasExactTarget)
        }
    }

    @Test("/terminal accepts a session that reported no TERM_PROGRAM at all")
    func storesHostOnlyRef() async throws {
        let store = SessionStore()
        try await VibeBuddyServer(store: store, token: "t0k", onJump: { _ in .activatedApp })
            .buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"session_id":"s","host_bundle_id":"com.anthropic.claude-code"}"#)) { _ in }
            let ref = try #require(await store.terminalRef(for: "s"))
            #expect(ref.termProgram == nil)
            #expect(ref.hostBundleId == "com.anthropic.claude-code")
            #expect(!ref.hasExactTarget)
        }
    }

    /// A ref carrying only a `cwd` names nothing: several sessions share a
    /// directory, and no emulator can be addressed by it alone. Storing it would
    /// turn the honest "no terminal recorded" into "couldn't locate this
    /// session's window", which reads like a bug in the jump.
    @Test("/terminal accepts but ignores a ref with nothing actionable in it")
    func ignoresUselessRef() async throws {
        final class Box: @unchecked Sendable { var jumped = 0 }
        let box = Box()
        let store = SessionStore()
        try await VibeBuddyServer(store: store, token: "t0k",
                                  onJump: { _ in box.jumped += 1; return .unsupported })
            .buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"session_id":"s","cwd":"/x/p","term_program":"","host_bundle_id":""}"#)) { res in
                #expect(res.status == .ok)   // never an error: a hook must not fail its session
            }
            #expect(await store.terminalRef(for: "s") == nil)
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { res in
                #expect(self.outcome(res.body) == "noTerminal")
            }
        }
        #expect(box.jumped == 0)
    }

    /// The re-capture on `UserPromptSubmit` skips the Ghostty probe, so the
    /// route has to merge rather than replace — end to end, through the store.
    @Test("a second /terminal POST merges into the first instead of replacing it")
    func mergesSuccessiveRefs() async throws {
        let store = SessionStore()
        try await VibeBuddyServer(store: store, token: "t0k", onJump: { _ in .focused })
            .buildApplication().test(.router) { client in
            _ = try await client.execute(uri: "/hook", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty","tty":"ttys003","ghostty_terminal_id":"7","cwd":"/x/p"}"#)) { _ in }
            _ = try await client.execute(uri: "/terminal", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty","tty":"ttys011","ghostty_terminal_id":"","cwd":"/x/p"}"#)) { _ in }
            let ref = try #require(await store.terminalRef(for: "s"))
            #expect(ref.ghosttyTerminalId == "7")
            #expect(ref.tty == "ttys011")
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

    /// The route reports whatever the jumper achieved — it no longer guesses from
    /// the ref, so every outcome the jumper can return has to survive the wire.
    @Test("the jumper's own verdict is what the phone reads back",
          arguments: [JumpOutcome.focused, .activatedApp, .unsupported])
    func reportsJumperOutcome(_ expected: JumpOutcome) async throws {
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k", onJump: { _ in expected })
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
                #expect(self.outcome(res.body) == expected.rawValue)
            }
        }
    }

    /// A Codex Desktop session is observed from its rollout, never from a hook,
    /// so `/terminal` is never called for it and the terminal jumper has nothing
    /// to work with. The route has to resolve its thread instead — that is the
    /// whole difference between a live jump button and a hidden one.
    @Test("/jump opens the thread for a Codex Desktop session that has no terminal ref")
    func jumpsToDesktopThread() async throws {
        final class Box: @unchecked Sendable {
            var threads: [String] = []
            var terminalJumps = 0
        }
        let box = Box()
        let store = SessionStore()
        let thread = "01a06114-dcc2-7402-8146-169c43e0cd2c"
        let server = VibeBuddyServer(
            store: store, token: "t0k",
            onJump: { _ in box.terminalJumps += 1; return .focused },
            onJumpToDesktopThread: { box.threads.append($0); return .focused })
        // The rollout tailer's own path into the store, thread id and all.
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: thread,
                                     agent: .codex, cwd: "/x/p",
                                     observationSource: .rollout,
                                     timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                     desktopThreadID: thread))
        try await server.buildApplication().test(.router) { client in
            #expect(await store.terminalRef(for: thread) == nil)
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"\#(thread)"}"#)) { res in
                #expect(res.status == .ok)
                #expect(self.outcome(res.body) == "focused")
            }
        }
        #expect(box.threads == [thread])
        #expect(box.terminalJumps == 0)
        // The phone gates its button on this, so it has to survive to the wire.
        let session = try #require(await store.snapshot(now: .now).sessions.first)
        #expect(session.desktopThreadID == thread)
        #expect(session.canJump)
        #expect(session.jumpsToDesktopThread)
    }

    @Test("a session with no terminal ref reports noTerminal and never runs the jumper")
    func reportsNoTerminal() async throws {
        final class Box: @unchecked Sendable { var jumped = 0 }
        let box = Box()
        try await VibeBuddyServer(store: SessionStore(), token: "t0k",
                                  onJump: { _ in box.jumped += 1; return .focused })
            .buildApplication().test(.router) { client in
            try await client.execute(uri: "/jump", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"ghost"}"#)) { res in
                #expect(self.outcome(res.body) == "noTerminal")
            }
        }
        #expect(box.jumped == 0)
    }
}
