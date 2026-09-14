import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Mac voice observed action identity")
struct VoiceActionContextTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String = "task", status: SessionStatus = .done) -> AgentSession {
        var value = AgentSession(id: id, agent: .codex, project: "project", status: status,
            statusSince: now, updatedAt: now)
        if status == .done { value.completionID = "round-1" }
        return value
    }

    @Test("mark read retains observed source, session and completion instead of retargeting")
    func exactCompletion() throws {
        let observed = session()
        var context = VoiceActionContext()
        #expect(context.target("project", sourceID: "mac", currentScope: [observed]) == nil)
        context.observe(sourceID: "mac", sessions: [observed])
        let target = try #require(context.target("project", sourceID: "mac", currentScope: [observed]))
        #expect(context.completionRequest(for: target, current: observed)
            == CompletionReadRequest(sourceID: "mac", sessionID: "task", completionID: "round-1"))
        var later = observed
        later.completionID = "round-2"
        #expect(context.completionRequest(for: target, current: later) == nil)
        #expect(context.completionRequest(for: target, current: session(status: .working)) == nil)
        #expect(context.target("project", sourceID: "other-mac", currentScope: [observed]) == nil)
        #expect(context.target("project", sourceID: "mac", currentScope: [session("replacement")]) == nil)
        #expect(context.target("project", sourceID: "mac", currentScope: []) == nil)
        #expect(context.target("project", sourceID: "mac", currentScope: [observed, session("duplicate")]) == nil)
        context.observe(sourceID: "mac", sessions: [observed, session("duplicate")])
        #expect(context.target("project", sourceID: "mac", currentScope: [observed]) == nil)
    }

    @Test("an old question never becomes a steer or an answer to a replacement question")
    func questionBinding() throws {
        var question = session(status: .needsResponse)
        question.waitKind = .question
        question.pendingQuestion = PendingQuestion(id: "q1", prompt: "Which one?")
        var context = VoiceActionContext()
        context.observe(sourceID: "mac", sessions: [question])
        let requestCandidate = context.instructionRequest(for: question, current: question, text: "First")
        let request = try #require(requestCandidate)
        #expect(request.intent == .answer && request.questionID == "q1")
        #expect(request.expectedStatusSince == now.timeIntervalSince1970)
        var replacement = question
        replacement.pendingQuestion = PendingQuestion(id: "q2", prompt: "Which next?")
        #expect(context.instructionRequest(for: question, current: replacement, text: "First") == nil)
        #expect(context.instructionRequest(for: question, current: session(status: .working), text: "First") == nil)
        let working = session(status: .working)
        #expect(context.instructionRequest(for: working, current: working, text: "First", answerOnly: true) == nil)
    }

    @Test("steer and continue retain request identity; an unknown receipt cannot resend")
    func instructionIdentityAndUnknown() async throws {
        var context = VoiceActionContext()
        let working = session(status: .working)
        context.observe(sourceID: "mac", sessions: [working])
        let requestCandidate = context.instructionRequest(for: working, current: working, text: "Update the README")
        let request = try #require(requestCandidate)
        #expect(request.intent == .steer)
        context.observe(sourceID: "mac", sessions: [working])
        let repeatedCandidate = context.instructionRequest(for: working, current: working, text: "Update the README")
        let repeated = try #require(repeatedCandidate)
        #expect(repeated.requestID == request.requestID)
        let done = session()
        #expect(context.instructionRequest(for: working, current: done, text: "Update the README") == nil)
        #expect(context.instructionRequest(for: done, current: done, text: "Update the README")?.intent == .continue)
        var channelChanged = working
        channelChanged.controlChannel = ControlChannel.none
        var knownChannel = working
        knownChannel.controlChannel = .appserver
        #expect(context.instructionRequest(for: knownChannel, current: channelChanged, text: "Update the README") == nil)
    }
    @Test("a voice request losing its receipt stays unknown without retry or continue fallback")
    func unknownDispatch() async throws {
        let store = SessionStore(sourceID: "mac")
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "task", agent: .codex,
            cwd: "/project", observationSource: .appserver, timestamp: Date()))
        let snapshot = await store.snapshot(now: Date())
        let working = try #require(snapshot.sessions.first)
        var context = VoiceActionContext()
        context.observe(sourceID: snapshot.sourceID, sessions: snapshot.sessions)
        let requestCandidate = context.instructionRequest(for: working, current: working, text: "Update README")
        let request = try #require(requestCandidate)
        actor Calls {
            var steers = 0
            var starts = 0
            func steer() -> Bool { steers += 1; return false }
            func start() -> Bool { starts += 1; return true }
        }
        let calls = Calls()
        let dispatch = AnswerDispatch(store: store, questions: QuestionRegistry(), inject: { _, _ in
            Issue.record("A voice instruction must never inject terminal text")
        }, steer: { _, _ in await calls.steer() }, startTurn: { _, _ in await calls.start() })
        #expect(await dispatch.deliver(request) == .unknown)
        context.observe(sourceID: snapshot.sourceID, sessions: snapshot.sessions)
        let repeatRequestCandidate = context.instructionRequest(for: working, current: working, text: "Update README")
        let repeatRequest = try #require(repeatRequestCandidate)
        #expect(await dispatch.deliver(repeatRequest) == .unknown)
        #expect(await calls.steers == 1)
        #expect(await calls.starts == 0)
    }

}
