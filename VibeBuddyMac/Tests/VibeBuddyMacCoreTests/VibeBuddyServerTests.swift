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

    @Test("/answer injects text into the session terminal")
    func answerInjectsIntoTerminal() async throws {
        final class Box: @unchecked Sendable { var answers: [(String, String)] = [] }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k",
                                     onAnswer: { ref, answer in box.answers.append((ref.tmuxPane ?? "", answer)) })
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
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
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { _ in }
            try await client.execute(uri: "/terminal", method: .post,
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

    @Test("/answer without a terminal ref is a no-op")
    func answerWithoutTerminalRefNoOps() async throws {
        final class Box: @unchecked Sendable { var answers: [String] = [] }
        let box = Box()
        let store = SessionStore()
        let server = VibeBuddyServer(store: store, token: "t0k",
                                     onAnswer: { _, answer in box.answers.append(answer) })
        try await server.buildApplication().test(.router) { client in
            try await client.execute(uri: "/hook", method: .post,
                                     body: ByteBuffer(string: #"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/demo"}"#)) { _ in }
            try await client.execute(uri: "/answer", method: .post,
                                     headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"s","answer":"Use main"}"#)) { res in
                #expect(res.status == .ok)
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
}
