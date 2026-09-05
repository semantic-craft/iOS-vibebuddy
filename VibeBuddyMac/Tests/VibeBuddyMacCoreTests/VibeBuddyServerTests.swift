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

    @Test("/device accepts structured phone registration")
    func deviceRegistration() async throws {
        final class Box: @unchecked Sendable { var reports: [DeviceRegistrationPayload] = [] }
        let box = Box()
        let server = VibeBuddyServer(store: SessionStore(), token: "t0k",
                                     onDevicePaired: { box.reports.append($0) })
        let body = #"{"token":"apns","name":"Hermes","model":"iPhone","systemVersion":"iOS 26.0"}"#

        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/device", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
            }
        }

        #expect(box.reports == [DeviceRegistrationPayload(token: "apns", name: "Hermes",
                                                          model: "iPhone", systemVersion: "iOS 26.0")])
        #expect(await server.deviceTokens.all() == ["apns"])
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
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: start)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: notif)) { res in
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

    @Test("/acknowledge is token-gated and clears a clean completion unread")
    func acknowledgeCompletion() async throws {
        let store = SessionStore()
        await store.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/x/demo"}"#.utf8),
                           receivedAt: Date(timeIntervalSince1970: 1))
        await store.ingest(Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/x/demo"}"#.utf8),
                           receivedAt: Date(timeIntervalSince1970: 2))
        let server = VibeBuddyServer(store: store, token: "t0k")

        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/acknowledge", method: .post,
                                     body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { response in
                #expect(response.status == .unauthorized)
            }
            #expect(await store.snapshot(now: .now).sessions.first?.hasUnreadCompletion == true)
            try await client.execute(uri: "/acknowledge", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"s"}"#)) { response in
                #expect(response.status == .ok)
            }
            #expect(await store.snapshot(now: .now).sessions.first?.presentationState == .idle)
        }
    }

    @Test("/answer injects text into the session terminal")
    func answerInjectsIntoTerminal() async throws {
        final class Box: @unchecked Sendable { var answers: [(String, String)] = [] }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k",
                                     onAnswer: { ref, answer in box.answers.append((ref.tmuxPane ?? "", answer)) })
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty","tmux":"/tmp/x,1,0","tmux_pane":"%9"}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/answer", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"s","answer":"Use the main branch"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(box.answers.count == 1)
            #expect(box.answers.first?.0 == "%9")
            #expect(box.answers.first?.1 == "Use the main branch")
        }
    }

    @Test("/answer trims and injects a non-empty answer")
    func answerTrimsBeforeInjecting() async throws {
        final class Box: @unchecked Sendable { var answers: [String] = [] }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k",
                                     onAnswer: { _, answer in box.answers.append(answer) })
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty","tmux":"/tmp/x,1,0","tmux_pane":"%9"}"#)) { _ in }
            try await client.execute(uri: "/answer", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"s","answer":"  Use the main branch\n"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(box.answers == ["Use the main branch"])
        }
    }

    @Test("/answer rejects blank answers")
    func answerRejectsBlank() async throws {
        final class Box: @unchecked Sendable { var answers: [String] = [] }
        let box = Box()
        let server = VibeBuddyServer(store: SessionStore(), token: "t0k",
                                     onAnswer: { _, answer in box.answers.append(answer) })
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/answer", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"s","answer":"   \n"}"#)) { res in
                #expect(res.status == .badRequest)
            }
            #expect(box.answers.isEmpty)
        }
    }

    @Test("/answer with nothing waiting and no terminal ref is accepted but not delivered")
    func answerWithoutTerminalRefNoOps() async throws {
        final class Box: @unchecked Sendable { var answers: [String] = [] }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k",
                                     onAnswer: { _, answer in box.answers.append(answer) })
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { _ in }
            try await client.execute(uri: "/answer", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"s","answer":"Use main"}"#)) { res in
                // Nothing waiting on the session and no pane to type into:
                // accepted but not delivered, so the phone can say so.
                #expect(res.status == .accepted)
            }
            #expect(box.answers.isEmpty)
        }
    }

    @Test("/answer without a token is 401")
    func answerUnauthorized() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/answer", method: .post,
                                     body: ByteBuffer(string: #"{"sessionId":"s","answer":"x"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // The CLI-hook routes (/hook, /approval, /terminal) used to be unauthenticated,
    // which let any local process — or a malicious web page hitting the LAN-bound
    // port — spoof sessions, fake approvals, or hijack a terminal ref. They now
    // require the same bearer token as the phone routes (daemon-security/01, ADR-0009).

    @Test("/hook without a token is 401, and the forged session is not ingested")
    func hookUnauthorized() async throws {
        let server = self.server(token: "t0k")
        let start = #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post, body: ByteBuffer(string: start)) { res in
                #expect(res.status == .unauthorized)
            }
        }
        let snap = await server.store.snapshot(now: Date())
        #expect(snap.sessions.isEmpty)
    }

    @Test("/hook with the wrong token is 401")
    func hookWrongToken() async throws {
        try await server(token: "right").buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer wrong"],
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("/terminal without a token is 401")
    func terminalUnauthorized() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/terminal", method: .post,
                                     body: ByteBuffer(string: #"{"session_id":"s","term_program":"ghostty"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("/approval without a token is 401")
    func approvalUnauthorized() async throws {
        try await server().buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                                     body: ByteBuffer(string: #"{"tool_name":"Bash","session_id":"s"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("/hook with the right token is accepted")
    func hookAuthorized() async throws {
        try await server(token: "t0k").buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("/hook accepts the token as a ?token= query param (native-http hooks, e.g. Qwen)")
    func hookAuthorizedViaQueryToken() async throws {
        try await server(token: "t0k").buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook?agent=qwen&token=t0k", method: .post,
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/hook?agent=qwen&token=nope", method: .post,
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s2","cwd":"/x/demo"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("/snapshot does not accept the token as a ?token= query param")
    func snapshotRejectsQueryToken() async throws {
        try await server(token: "t0k").buildApplication().test(.router) { client in
            try await client.execute(uri: "/snapshot?token=t0k", method: .get) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("an empty configured token fails closed on both auth surfaces")
    func emptyTokenFailsClosed() async throws {
        try await server(token: "").buildApplication().test(.router) { client in
            try await client.execute(uri: "/snapshot", method: .get,
                                     headers: [.authorization: "Bearer "]) { res in
                #expect(res.status == .unauthorized)
            }
            try await client.execute(uri: "/hook?token=", method: .post) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }
}
