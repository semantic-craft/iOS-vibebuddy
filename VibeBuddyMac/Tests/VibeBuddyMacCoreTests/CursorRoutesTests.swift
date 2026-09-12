import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Cursor's blocking `preToolUse` gate for a shell command.
private func cursorShell(_ command: String) -> String {
    #"{"hook_event_name":"beforeShellExecution","conversation_id":"c1","generation_id":"g1","#
        + #""workspace_roots":["/x/p"],"cwd":"/x/p","command":"\#(command)","sandbox":false}"#
}

/// Cursor's `preToolUse` gate on its own question tool.
private let cursorQuestion = #"""
{"hook_event_name":"preToolUse","conversation_id":"c1","generation_id":"g1","workspace_roots":["/x/p"],"cwd":"/x/p","tool_name":"AskQuestion","tool_use_id":"t1","tool_input":{"title":"Pick a branch","questions":[{"id":"branch","prompt":"Which branch?","options":[{"id":"main","label":"main"},{"id":"dev","label":"dev"}]}]}}
"""#

@Suite("Cursor routes")
struct CursorRoutesTests {
    private func server(store: SessionStore,
                        approvalRegistry: ApprovalRegistry = ApprovalRegistry(),
                        questionRegistry: QuestionRegistry = QuestionRegistry(),
                        followups: CursorFollowupQueue = CursorFollowupQueue(),
                        presence: @escaping @Sendable (String) async -> Bool = { _ in false },
                        timeout: Duration = .seconds(5)) -> VibeBuddyServer {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vbcursor-\(UUID().uuidString).json")
        return VibeBuddyServer(store: store, token: "t0k",
                               approvalRegistry: approvalRegistry,
                               rules: { _ in PermissionRules(allow: [], deny: []) },
                               allowStore: VibeBuddyAllowStore(url: storeURL),
                               questionRegistry: questionRegistry,
                               presence: presence,
                               approvalTimeout: timeout,
                               approvalID: { "a1" },
                               cursorFollowups: followups)
    }

    private func waitForApproval(_ store: SessionStore) async throws {
        for _ in 0..<1000 {
            let sessions = await store.snapshot(now: Date()).sessions
            if sessions.first(where: { $0.id == "c1" })?.pendingApproval != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("no Cursor approval ever became pending")
    }

    private func waitForQuestion(_ store: SessionStore) async throws {
        for _ in 0..<1000 {
            let sessions = await store.snapshot(now: Date()).sessions
            if sessions.first(where: { $0.id == "c1" })?.pendingQuestion != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("no Cursor question ever became pending")
    }

    @Test("a phone decision answers Cursor's own permission contract",
          arguments: [("allow", "allow"), ("deny", "deny")])
    func phoneDecisionReachesCursor(decision: String, expected: String) async throws {
        let store = SessionStore()
        let registry = ApprovalRegistry()
        let srv = server(store: store, approvalRegistry: registry)
        try await srv.buildApplication().test(.router) { client in
            let gate = Task {
                try await client.execute(uri: "/approval?agent=cursor", method: .post,
                    headers: [.authorization: "Bearer t0k"],
                    body: ByteBuffer(string: cursorShell("rm -rf build"))) { res in
                    let text = String(buffer: res.body)
                    let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                    #expect(json?["permission"] as? String == expected)
                    // Nothing Claude-shaped: Cursor would not read it.
                    #expect(json?["hookSpecificOutput"] == nil)
                }
            }
            try await waitForApproval(store)
            // The gate doubles as the tool signal, so the row is already working.
            let session = await store.snapshot(now: Date()).sessions.first { $0.id == "c1" }
            #expect(session?.status == .needsResponse)
            #expect(session?.pendingApproval?.tool == "Bash")
            #expect(session?.pendingApproval?.commandPreview == "rm -rf build")
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"a1","decision":"\#(decision)"}"#)) { res in
                #expect(res.status == .ok)
            }
            try await gate.value
        }
    }

    /// Silence is the fail-open answer: Cursor reads an empty body as "no
    /// opinion" and raises its own prompt.
    @Test func aTimedOutApprovalPrintsNothing() async throws {
        let store = SessionStore()
        let srv = server(store: store, timeout: .milliseconds(30))
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval?agent=cursor", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: cursorShell("pwd"))) { res in
                #expect(res.status == .ok)
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    /// Read-only work is never worth a card, in any mode.
    @Test func aReadIsAllowedWithoutAskingAnyone() async throws {
        let store = SessionStore()
        let srv = server(store: store)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval?agent=cursor", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"hook_event_name":"preToolUse","conversation_id":"c1","tool_name":"Read","tool_input":{"path":"/a/b.swift"}}"#)) { res in
                let json = (try? JSONSerialization.jsonObject(with: Data(String(buffer: res.body).utf8))) as? [String: Any]
                #expect(json?["permission"] as? String == "allow")
            }
            let session = await store.snapshot(now: Date()).sessions.first { $0.id == "c1" }
            #expect(session?.pendingApproval == nil)
        }
    }

    @Test func aQuestionIsAnsweredFromThePhone() async throws {
        let store = SessionStore()
        let questions = QuestionRegistry()
        let srv = server(store: store, questionRegistry: questions)
        try await srv.buildApplication().test(.router) { client in
            let gate = Task {
                try await client.execute(uri: "/approval?agent=cursor", method: .post,
                    headers: [.authorization: "Bearer t0k"],
                    body: ByteBuffer(string: cursorQuestion)) { res in
                    let json = (try? JSONSerialization.jsonObject(with: Data(String(buffer: res.body).utf8))) as? [String: Any]
                    // Denying the question *is* the delivery: Cursor has no
                    // contract for returning a tool result from a hook.
                    #expect(json?["permission"] as? String == "deny")
                    #expect((json?["agent_message"] as? String)?.contains("dev") == true)
                    #expect((json?["user_message"] as? String)?.contains("vibebuddy") == true)
                }
            }
            try await waitForQuestion(store)
            let session = await store.snapshot(now: Date()).sessions.first { $0.id == "c1" }
            #expect(session?.status == .needsResponse)
            #expect(session?.waitKind == .question)
            #expect(session?.pendingQuestion?.prompt == "Which branch?")
            #expect(session?.pendingQuestion?.isAnswerable == true)
            #expect(session?.pendingQuestion?.options.map(\.label) == ["main", "dev"])
            try await client.execute(uri: "/answer", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"c1","intent":"answer","answers":{"branch":["dev"]}}"#)) { res in
                #expect(res.status == .ok)
            }
            try await gate.value
        }
    }

    /// At the keyboard, Cursor's own picker takes the answer and the phone only
    /// gets to watch.
    @Test func aQuestionAskedWhileYouAreAtTheMacIsReadOnly() async throws {
        let store = SessionStore()
        let srv = server(store: store, presence: { _ in true })
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval?agent=cursor", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: cursorQuestion)) { res in
                #expect(res.status == .ok)
                #expect(res.body.readableBytes == 0)
            }
            let session = await store.snapshot(now: Date()).sessions.first { $0.id == "c1" }
            #expect(session?.pendingQuestion?.isAnswerable == false)
        }
    }

    @Test func theStopHookCollectsWhateverThePhoneQueued() async throws {
        let store = SessionStore()
        let followups = CursorFollowupQueue()
        let srv = server(store: store, followups: followups)
        try await srv.buildApplication().test(.router) { client in
            // Nothing queued: the turn ends exactly as it would with no hook.
            try await client.execute(uri: "/cursor-followup", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"conversation_id":"c1","hook_event_name":"stop","status":"completed"}"#)) { res in
                #expect(res.status == .ok)
                #expect(res.body.readableBytes == 0)
            }
            await followups.queue(conversationID: "c1", text: "also update the README")
            try await client.execute(uri: "/cursor-followup", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"conversation_id":"c1","hook_event_name":"stop","status":"completed"}"#)) { res in
                let json = (try? JSONSerialization.jsonObject(with: Data(String(buffer: res.body).utf8))) as? [String: Any]
                #expect(json?["followup_message"] as? String == "also update the README")
            }
            // Collected once: Cursor submits it itself.
            try await client.execute(uri: "/cursor-followup", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"conversation_id":"c1"}"#)) { res in
                #expect(res.body.readableBytes == 0)
            }
        }
    }

    @Test func theFollowupRouteNeedsTheToken() async throws {
        let srv = server(store: SessionStore())
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/cursor-followup", method: .post,
                body: ByteBuffer(string: #"{"conversation_id":"c1"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    /// A running Cursor turn cannot be interrupted, so a supplement is queued
    /// for its `stop` hook instead — and the receipt says accepted only because
    /// it really was queued.
    @Test func steeringARunningCursorTurnQueuesIt() async throws {
        let store = SessionStore()
        let followups = CursorFollowupQueue()
        let srv = server(store: store, followups: followups)
        let now = Date()
        await store.ingest(Data(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"go","workspace_roots":["/x/p"]}"#.utf8),
                           agent: .cursor, receivedAt: now)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/answer", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"c1","intent":"steer","answer":"also update the README"}"#)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains("accepted"))
            }
        }
        #expect(await followups.take(conversationID: "c1") == "also update the README")
    }

    @Test func stoppingACursorTurnIsRefusedRatherThanAttempted() async throws {
        let store = SessionStore()
        let srv = server(store: store)
        let now = Date()
        await store.ingest(Data(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"c1","prompt":"go","workspace_roots":["/x/p"]}"#.utf8),
                           agent: .cursor, receivedAt: now)
        let since = try #require(await store.snapshot(now: now).sessions.first { $0.id == "c1" }?.statusSince)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/answer", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"c1","intent":"stop","expectedStatusSince":\#(since.timeIntervalSince1970)}"#)) { res in
                #expect(res.status == .conflict)
                #expect(String(buffer: res.body).contains("refused"))
            }
        }
    }
}
