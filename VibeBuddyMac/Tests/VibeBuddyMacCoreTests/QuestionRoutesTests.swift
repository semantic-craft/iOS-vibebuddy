import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Claude's `AskUserQuestion` arrives on the blocking PreToolUse hook; the
/// phone's answers go back in the tool's own `updatedInput`.
@Suite("Claude question routes")
struct QuestionRoutesTests {
    private let askPayload = #"""
    {"hook_event_name":"PreToolUse","session_id":"qs","cwd":"/x/p","tool_name":"AskUserQuestion","tool_use_id":"toolu_q",
     "tool_input":{"questions":[
       {"question":"How should I format the output?","header":"Format","multiSelect":false,
        "options":[{"label":"Summary","description":"Brief"},{"label":"Detailed","description":"Full"}]},
       {"question":"Which sections should I include?","header":"Sections","multiSelect":true,
        "options":[{"label":"Introduction","description":"Opening"},{"label":"Conclusion","description":"Closing"}]}]}}
    """#

    private final class InjectionRecorder: @unchecked Sendable {
        let lock = NSLock(); var typed: [String] = []
        func record(_ text: String) { lock.withLock { typed.append(text) } }
        var all: [String] { lock.withLock { typed } }
    }

    private func server(store: SessionStore, timeout: Duration = .seconds(5),
                        recorder: InjectionRecorder? = nil) -> VibeBuddyServer {
        VibeBuddyServer(store: store, token: "t0k", port: 9876,
                        approvalRegistry: ApprovalRegistry(),
                        rules: { _ in PermissionRules(allow: [], deny: []) },
                        allowStore: VibeBuddyAllowStore(url: FileManager.default.temporaryDirectory
                            .appendingPathComponent("vbq-\(UUID().uuidString).json")),
                        approvalTimeout: timeout, approvalID: { "q1" },
                        onAnswer: { _, text in recorder?.record(text) })
    }

    private func waitForQuestion(_ store: SessionStore) async throws {
        for _ in 0..<1000 {
            if await store.snapshot(now: Date()).sessions.first(where: { $0.id == "qs" })?.pendingQuestion != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("no question ever became pending")
    }

    private func decode(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    @Test("the hook holds with a structured card; single, multi and typed answers come back keyed by question text")
    func answersFlowBack() async throws {
        let store = SessionStore()
        try await server(store: store).buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: askPayload)) { res -> String in
                String(buffer: res.body)
            }
            try await waitForQuestion(store)
            let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "qs" })
            #expect(session.status == .needsResponse)
            #expect(session.waitKind == .question)
            let question = try #require(session.pendingQuestion)
            #expect(question.items.count == 2)
            #expect(question.items[0].header == "Format")
            #expect(question.items[1].multiSelect)
            #expect(question.prompt == "How should I format the output?")

            let answers = #"{"sessionId":"qs","answers":{"q1":["Summary"],"q2":["Introduction","Conclusion","and a glossary"]}}"#
            try await client.execute(uri: "/answer", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: answers)) { res in
                #expect(res.status == .ok)
            }
            let reply = decode(try await held)
            let output = try #require(reply["hookSpecificOutput"] as? [String: Any])
            #expect(output["hookEventName"] as? String == "PreToolUse")
            #expect(output["permissionDecision"] as? String == "allow")
            let updated = try #require(output["updatedInput"] as? [String: Any])
            #expect((updated["questions"] as? [[String: Any]])?.count == 2)     // original questions kept
            let byText = try #require(updated["answers"] as? [String: Any])
            #expect(byText["How should I format the output?"] as? String == "Summary")
            #expect(byText["Which sections should I include?"] as? [String] == ["Introduction", "Conclusion", "and a glossary"])
            #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "qs" }?.pendingQuestion == nil)
        }
    }

    @Test("plain text from an older client answers the first question")
    func plainTextAnswersFirst() async throws {
        let store = SessionStore()
        try await server(store: store).buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: askPayload)) { res -> String in
                String(buffer: res.body)
            }
            try await waitForQuestion(store)
            try await client.execute(uri: "/answer", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"qs","answer":"Detailed"}"#)) { res in
                #expect(res.status == .ok)
            }
            let updated = decode(try await held)["hookSpecificOutput"].flatMap { ($0 as? [String: Any])?["updatedInput"] as? [String: Any] }
            let byText = try #require(updated?["answers"] as? [String: Any])
            #expect(byText["How should I format the output?"] as? String == "Detailed")
            #expect(byText["Which sections should I include?"] == nil)
        }
    }

    @Test("after the hook times out an Answer is refused and is not typed as an instruction")
    func timeoutDoesNotTurnAnswerIntoInstruction() async throws {
        let store = SessionStore()
        let recorder = InjectionRecorder()
        let srv = server(store: store, timeout: .milliseconds(200), recorder: recorder)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: askPayload)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).isEmpty)          // Claude shows its own UI
            }
            #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "qs" }?.pendingQuestion != nil)
            await store.setTerminalRef(sessionID: "qs", TerminalRef(termProgram: "tmux", tty: "ttys001", tmux: "/tmp/sock,1,0", tmuxPane: "%1"))
            try await client.execute(uri: "/answer", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"sessionId":"qs","intent":"answer","requestId":"late","answers":{"q1":["Summary"]}}"#)) { res in
                #expect(res.status == .conflict)
            }
            #expect(recorder.all.isEmpty)
            #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "qs" }?.pendingQuestion != nil)
        }
    }

    @Test("a transcript read never replaces the full question list a hook delivered")
    func transcriptKeepsStructuredQuestion() async throws {
        let store = SessionStore()
        let full = try #require(AskUserQuestionInput.pendingQuestion(from: decode(askPayload)["tool_input"] as? [String: Any] ?? [:], id: "q1"))
        let now = Date()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "qs", agent: .claudeCode, cwd: "/x/p", timestamp: now))
        await store.beginQuestion(sessionID: "qs", full, at: now)
        // A transcript read rides the enrichment path; it only knows the first question.
        await store.ingest(HookEvent(kind: .sessionMetadataChanged, sessionID: "qs", agent: .claudeCode,
                                     timestamp: now.addingTimeInterval(1),
                                     enrichment: TranscriptInfo(pendingQuestion: PendingQuestion(id: "t", prompt: "How should I format the output?"))))
        let session = try #require(await store.snapshot(now: now).sessions.first { $0.id == "qs" })
        #expect(session.status == .needsResponse)
        #expect(session.pendingQuestion?.questions?.count == 2)
    }

    @Test("a Codex PermissionRequest steps aside while the daemon reports the session")
    func codexGateStepsAside() async throws {
        let store = SessionStore()
        let now = Date()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "cs", agent: .codex, cwd: "/x/p",
                                     observationSource: .appserver, timestamp: now))
        let body = #"{"hook_event_name":"PermissionRequest","session_id":"cs","cwd":"/x/p","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        try await server(store: store).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval?agent=codex", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: body)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).isEmpty)
            }
        }
        #expect(await store.snapshot(now: now).sessions.first { $0.id == "cs" }?.pendingApproval == nil)
    }
}
