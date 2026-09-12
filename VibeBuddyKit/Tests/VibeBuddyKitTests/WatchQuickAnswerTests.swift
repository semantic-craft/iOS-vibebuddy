import XCTest
@testable import VibeBuddyKit

/// What a wrist may answer with, and what it may claim happened to the answer.
///
/// The rule under test is the one the card draws *and* the one the iPhone
/// re-runs on the tap, so these assertions are about the two of them agreeing:
/// a phrase is only ever offered where an answer would actually be forwarded.
final class WatchQuickAnswerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func asking(options: [QuestionOption] = [],
                        answerable: Bool = true,
                        agent: AgentKind = .codex) -> AgentSession {
        AgentSession(id: "s-ask", agent: agent, project: "docs-review", status: .needsResponse,
                     waitKind: .question,
                     pendingQuestion: PendingQuestion(id: "q-1", prompt: "Which tone?",
                                                      options: options, answerable: answerable),
                     statusSince: now, updatedAt: now)
    }

    private func alert(_ session: AgentSession) throws -> WatchAlert {
        let state = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [session], serverTime: now),
            quotas: [], relay: .live, now: now)
        return try XCTUnwrap(state.topAlert)
    }

    // MARK: which quick answers are offered

    func testAnOpenQuestionOffersTheFixedPhrasesInTheirFixedOrder() throws {
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert(asking())))
        XCTAssertEqual(choices.source, .phrases)
        XCTAssertEqual(choices.replies.map(\.id),
                       WatchAnswerPhrase.allCases.map { "phrase:\($0.rawValue)" })
        // The go-ahead leads: it is what most checkpoints are answered with,
        // and the first button is where the eye lands.
        XCTAssertEqual(choices.replies.first, .phrase(.goAhead))
        // Every phrase carries the text it will actually send.
        XCTAssertEqual(WatchQuickReply.phrase(.goAhead).text, WatchAnswerPhrase.goAhead.text)
        XCTAssertFalse(WatchAnswerPhrase.allCases.contains { $0.text.isEmpty })
    }

    func testTheAgentsOwnChoicesReplaceTheGeneralPhrasesEntirely() throws {
        let session = asking(options: [QuestionOption(id: "tight", label: "Tighten"),
                                       QuestionOption(id: "plain", label: "Plain language")])
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert(session)))
        XCTAssertEqual(choices.source, .options)
        // "Run the tests first" is not an answer to "Tighten or plain
        // language?", so the general set is replaced rather than appended to.
        XCTAssertEqual(choices.replies, [.option("Tighten"), .option("Plain language")])
        XCTAssertFalse(choices.replies.contains { if case .phrase = $0 { return true }; return false })
    }

    func testAPromptWithAFreeTextQuestionIsNotTheWristsToFinish() throws {
        // A free-text answer lands on the first item alone, so a wrist that
        // offered one tap would answer one question out of three and say
        // nothing about the other two — and a wrist cannot type the essay
        // the second question wants, so the whole prompt stays on the phone.
        var session = asking()
        session.pendingQuestion = PendingQuestion(
            id: "q-1", prompt: "Which tone?",
            questions: [QuestionItem(id: "a", text: "Which tone?",
                                     options: [QuestionOption(id: "t", label: "Tighten")]),
                        QuestionItem(id: "b", text: "Ship it today?")])
        let card = try alert(session)
        XCTAssertNil(card.pendingId)
        XCTAssertNil(card.questions)
        XCTAssertFalse(card.isAnswerable)
        XCTAssertNil(WatchQuickAnswers.resolve(for: card))
        // The wait is still remotely answerable, just not from a wrist.
        XCTAssertEqual(card.handling, .remoteAvailable)

        // And the rule runs again on the tap, so a forged payload naming the
        // real question id is refused rather than half-answering — whether it
        // sends one string or a set of picks for the questions it can pick.
        var gate = WatchSessionActionGate()
        let forged = WatchSessionActionRequest(attemptId: "t-1", sessionId: "s-ask",
                                               action: .answer(pendingId: "q-1", text: "Tighten"))
        XCTAssertEqual(gate.admit(forged, sessions: [session]), .refused)
        let picked = WatchSessionActionRequest(attemptId: "t-2", sessionId: "s-ask",
                                               action: .answerAll(pendingId: "q-1",
                                                                  answers: ["a": ["Tighten"]]))
        XCTAssertEqual(gate.admit(picked, sessions: [session]), .refused)

        // One single-select question is still the ordinary case.
        XCTAssertNotNil(WatchQuickAnswers.resolve(for: try alert(asking())))
    }

    // MARK: walking a prompt one question at a time

    /// Cursor's usual `AskQuestion`: two questions, each with its own choices,
    /// the second taking several.
    private var twoPickable: AgentSession {
        var session = asking()
        session.pendingQuestion = PendingQuestion(
            id: "q-1", prompt: "Which tone?",
            questions: [QuestionItem(id: "tone", text: "Which tone?",
                                     options: [QuestionOption(id: "t", label: "Tighten"),
                                               QuestionOption(id: "p", label: "Plain language",
                                                              value: "plain")]),
                        QuestionItem(id: "files", text: "Which files?",
                                     options: [QuestionOption(id: "x", label: "README"),
                                               QuestionOption(id: "y", label: "CHANGELOG")],
                                     multiSelect: true)])
        return session
    }

    func testAPromptWhoseEveryQuestionOffersChoicesIsWalkedAndSentOnce() throws {
        let session = twoPickable
        let card = try alert(session)

        // The wrist gets the identity and every question — text, choices with
        // their values, and which ones take several picks.
        XCTAssertEqual(card.pendingId, "q-1")
        XCTAssertTrue(card.isAnswerable)
        XCTAssertEqual(card.handling, .remoteAvailable)
        let items = try XCTUnwrap(card.questions)
        XCTAssertEqual(items.map(\.id), ["tone", "files"])
        XCTAssertEqual(items.map(\.text), ["Which tone?", "Which files?"])
        XCTAssertEqual(items.map(\.multiSelect), [false, true])
        XCTAssertEqual(items[0].options.map(\.label), ["Tighten", "Plain language"])
        XCTAssertEqual(items[0].options.map(\.value), ["Tighten", "plain"])
        // Not one string: the first question's choices are not the answer.
        XCTAssertNil(WatchQuickAnswers.resolve(for: card))
        // The card still captions the first question, as every card does.
        XCTAssertEqual(card.options, ["Tighten", "Plain language"])

        // The whole set goes in one action, bound to the prompt.
        var action = WatchSessionActionState()
        let request = try XCTUnwrap(action.begin(
            alert: card, answers: ["tone": ["plain"], "files": ["CHANGELOG", "README"]],
            attemptId: "t-1"))
        XCTAssertEqual(request.action, .answerAll(pendingId: "q-1",
                                                  answers: ["tone": ["plain"],
                                                            "files": ["README", "CHANGELOG"]]))
        XCTAssertEqual(action.action?.pendingId, "q-1")
        XCTAssertNil(action.action?.answerText)
        XCTAssertEqual(action.action?.answers?["files"], ["README", "CHANGELOG"])

        // The iPhone re-runs the rule and forwards exactly what was checked.
        let gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request, sessions: [session]),
                       .answerAll(pendingId: "q-1", answers: ["tone": ["plain"],
                                                              "files": ["README", "CHANGELOG"]]))

        // Accepted is not answered: the attempt stays until a snapshot says
        // the prompt is gone, exactly as a one-string answer does.
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        let asking = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [session], serverTime: now), quotas: [], relay: .live, now: now)
        action.reconcile(with: asking)
        XCTAssertNotNil(action.action)
        XCTAssertNotNil(asking.resolvingAnswer("q-1"))
        action.reconcile(with: asking.resolvingAnswer("q-1"))
        XCTAssertNil(action.action)

        // A restored cache keeps neither the identity nor the questions.
        let cached = WatchStoredState(state: asking, queue: WatchCompletionQueue()).state
        XCTAssertNil(cached.alerts.first?.questions)
        XCTAssertFalse(cached.alerts.first?.isAnswerable ?? true)
    }

    func testAPartialOrInventedAnswerSetNeverLeavesTheWristAndIsRefusedAnyway() throws {
        let session = twoPickable
        let card = try alert(session)
        var action = WatchSessionActionState()
        let gate = WatchSessionActionGate()
        func forged(_ answers: QuestionAnswers, _ attempt: String) -> WatchSessionActionRequest {
            WatchSessionActionRequest(attemptId: attempt, sessionId: "s-ask",
                                      action: .answerAll(pendingId: "q-1", answers: answers))
        }

        let incomplete: [(String, QuestionAnswers)] = [
            ("one question missing", ["tone": ["Tighten"]]),
            ("an empty pick", ["tone": [], "files": ["README"]]),
            ("a choice the agent never offered", ["tone": ["Loosen"], "files": ["README"]]),
            ("a question the agent never asked", ["tone": ["Tighten"], "files": ["README"], "x": ["y"]]),
            ("two picks for a single-select", ["tone": ["Tighten", "plain"], "files": ["README"]]),
        ]
        for (why, answers) in incomplete {
            XCTAssertNil(action.begin(alert: card, answers: answers, attemptId: "t-1"), why)
            XCTAssertEqual(gate.admit(forged(answers, "t-1"), sessions: [session]), .refused, why)
        }

        // Ids are accepted for values and normalized, so an agent that keeps
        // the two apart still gets the value it will read.
        XCTAssertEqual(gate.admit(forged(["tone": ["p"], "files": ["y", "y"]], "t-2"), sessions: [session]),
                       .answerAll(pendingId: "q-1", answers: ["tone": ["plain"], "files": ["CHANGELOG"]]))
        // The wrong prompt is the wrong prompt.
        var moved = session
        moved.pendingQuestion = PendingQuestion(id: "q-2", prompt: "Still?", questions: session.pendingQuestion?.questions)
        XCTAssertEqual(gate.admit(forged(["tone": ["p"], "files": ["y"]], "t-3"), sessions: [moved]), .refused)
        // A one-string answer to a walked prompt is still one answer for two
        // questions, and still refused.
        let text = WatchSessionActionRequest(attemptId: "t-4", sessionId: "s-ask",
                                             action: .answer(pendingId: "q-1", text: "Tighten"))
        XCTAssertEqual(gate.admit(text, sessions: [session]), .refused)
    }

    func testOneMultiSelectQuestionIsWalkedRatherThanRefused() throws {
        var multi = asking()
        multi.pendingQuestion = PendingQuestion(
            id: "q-1", prompt: "Which files?",
            questions: [QuestionItem(id: "a", text: "Which files?",
                                     options: [QuestionOption(id: "x", label: "One"),
                                               QuestionOption(id: "y", label: "Two")],
                                     multiSelect: true)])
        let card = try alert(multi)
        XCTAssertEqual(card.questions?.count, 1)
        XCTAssertEqual(card.questions?.first?.multiSelect, true)
        XCTAssertNil(WatchQuickAnswers.resolve(for: card), "two picks are not one string")
        let gate = WatchSessionActionGate()
        let both = WatchSessionActionRequest(attemptId: "t-1", sessionId: "s-ask",
                                             action: .answerAll(pendingId: "q-1", answers: ["a": ["Two", "One"]]))
        XCTAssertEqual(gate.admit(both, sessions: [multi]),
                       .answerAll(pendingId: "q-1", answers: ["a": ["One", "Two"]]))

        // One single-select question with choices keeps the one-string path:
        // no `questions`, the choices as quick replies, nothing new on screen.
        let single = try alert(asking(options: [QuestionOption(id: "t", label: "Tighten")]))
        XCTAssertNil(single.questions)
        XCTAssertEqual(WatchQuickAnswers.resolve(for: single)?.source, .options)
    }

    func testTheAnswerSetRoundTripsAndTheOneStringFormStillDecodes() throws {
        let request = WatchSessionActionRequest(
            attemptId: "t-1", sessionId: "s-ask",
            action: .answerAll(pendingId: "q-1", answers: ["tone": ["plain"], "files": ["README", "CHANGELOG"]]))
        let payload = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(WatchSessionActionRequest.self, from: payload), request)
        let json = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(json.contains("\"answerAll\""))
        XCTAssertFalse(json.contains("token"))

        // What an older Watch sends, byte for byte, still means what it meant.
        let legacy = Data(#"{"attemptId":"t-2","sessionId":"s-ask","action":{"answer":{"pendingId":"q-1","text":"yes"}}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WatchSessionActionRequest.self, from: legacy),
                       WatchSessionActionRequest(attemptId: "t-2", sessionId: "s-ask",
                                                 action: .answer(pendingId: "q-1", text: "yes")))
        // And a relay that predates the walk reads as a one-string alert.
        let old = Data(#"{"sessionId":"s","agent":"codex","project":"p","waitKind":"question","options":[],"waitingSince":0}"#.utf8)
        let alert = try JSONDecoder().decode(WatchAlert.self, from: old)
        XCTAssertNil(alert.questions)
        XCTAssertNil(alert.pendingId)
    }

    func testOptionsThatDidNotFitAreCountedRatherThanDropped() throws {
        let many = (1...9).map { QuestionOption(id: "o\($0)", label: "Choice \($0)") }
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert(asking(options: many))))
        XCTAssertEqual(choices.replies.count, WatchQuickAnswers.maxOptions)
        // Six of nine presented as the whole list would be a quiet lie about
        // what the agent asked.
        XCTAssertEqual(choices.omittedOptions, 3)
        // Blank and duplicate labels were never offerable, so they are not
        // counted as choices the wearer is missing.
        let messy = [" Keep ", "Keep", "  "].enumerated()
            .map { QuestionOption(id: "m\($0.offset)", label: $0.element) }
        let tidy = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert(asking(options: messy))))
        XCTAssertEqual(tidy.replies, [.option("Keep")])
        XCTAssertEqual(tidy.omittedOptions, 0)
    }

    func testALostMacReplyIsCarriedToTheWristAsUnknown() throws {
        // The far link is where a receipt is most likely to go missing: the Mac
        // takes the answer, acts on it, and its 200 never comes back.
        let card = try alert(asking())
        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: card, answer: "Yes, go ahead.", attemptId: "t-1"))
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .unknown))
        XCTAssertEqual(action.action?.phase, .unknown)
        XCTAssertFalse(action.isBusy)
        // Settled: a late reply cannot turn it into an invitation to resend.
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .failed))
        XCTAssertEqual(action.action?.phase, .unknown)
    }

    func testOptionLabelsAreCleanedBoundedAndDeduplicated() throws {
        let messy = ([" Tighten ", "Tighten", "   ", "Plain"] + (1...8).map { "Extra \($0)" })
            .enumerated().map { QuestionOption(id: "o\($0.offset)", label: $0.element) }
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert(asking(options: messy))))
        XCTAssertEqual(choices.source, .options)
        XCTAssertEqual(choices.replies.count, WatchQuickAnswers.maxOptions)
        XCTAssertEqual(choices.replies.prefix(3), [.option("Tighten"), .option("Plain"),
                                                   .option("Extra 1")])
    }

    func testAQuestionWhoseOptionsAreAllBlankFallsBackToThePhrases() throws {
        let blank = [QuestionOption(id: "a", label: "  "), QuestionOption(id: "b", label: "")]
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: alert(asking(options: blank))))
        XCTAssertEqual(choices.source, .phrases)
    }

    // MARK: where no quick answer may appear

    func testAReadOnlyQuestionOffersNothingAndKeepsItsReason() throws {
        let readOnly = try alert(asking(answerable: false))
        XCTAssertFalse(readOnly.isAnswerable)
        XCTAssertNil(WatchQuickAnswers.resolve(for: readOnly))
        // The card falls through to this sentence instead of a button.
        XCTAssertEqual(readOnly.handling, .macNativePrompt)

        let grok = try alert(asking(agent: .grokBot))
        XCTAssertNil(WatchQuickAnswers.resolve(for: grok))
        XCTAssertEqual(grok.handling, .macGrokBot)
    }

    func testAPermissionIsNeverAnswerableFromTheWrist() throws {
        let session = AgentSession(
            id: "s-build", agent: .claudeCode, project: "ios-vibebuddy",
            status: .needsResponse, waitKind: .permission,
            pendingApproval: PendingApproval(id: "ap-1", tool: "Bash",
                                             commandPreview: "swift test…", command: "swift test"),
            statusSince: now, updatedAt: now)
        let permission = try alert(session)
        XCTAssertTrue(permission.isDecidable)
        XCTAssertNil(WatchQuickAnswers.resolve(for: permission))
    }

    func testARestoredCacheOffersNoQuickAnswers() throws {
        let live = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [asking(options: [QuestionOption(id: "t", label: "Tighten")])],
                               serverTime: now),
            quotas: [], relay: .live, now: now)
        XCTAssertNotNil(WatchQuickAnswers.resolve(for: try XCTUnwrap(live.topAlert)))
        // The question text and the option labels are live-only; without them
        // the card is a memory, and a memory takes no answer.
        let cached = WatchStoredState(state: live, queue: WatchCompletionQueue()).state
        for alert in cached.alerts {
            XCTAssertNil(WatchQuickAnswers.resolve(for: alert))
        }
    }

    // MARK: sending one

    func testAQuickReplyTravelsAsTheTextItShowed() throws {
        let session = asking(options: [QuestionOption(id: "tight", label: "Tighten")])
        let card = try alert(session)
        let choices = try XCTUnwrap(WatchQuickAnswers.resolve(for: card))
        let reply = try XCTUnwrap(choices.replies.first)

        var action = WatchSessionActionState()
        let request = try XCTUnwrap(action.begin(alert: card, answer: reply.text, attemptId: "t-1"))
        XCTAssertEqual(request.action, .answer(pendingId: "q-1", text: "Tighten"))
        // What was shown is what the iPhone forwards: no relabelling in between.
        var gate = WatchSessionActionGate()
        XCTAssertEqual(gate.admit(request, sessions: [session]),
                       .answer(pendingId: "q-1", text: "Tighten"))
        XCTAssertEqual(action.action?.answerText, "Tighten")
        XCTAssertEqual(action.action?.pendingId, "q-1")
        XCTAssertNil(action.action?.approvalId)
        XCTAssertFalse(action.action?.isStop ?? true)
    }

    func testASecondAnswerTapSendsNothingWhileOneIsInFlight() throws {
        let card = try alert(asking())
        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: card, answer: "Yes, go ahead.", attemptId: "t-1"))
        XCTAssertTrue(action.isBusy)
        XCTAssertNil(action.begin(alert: card, answer: "No, don't do that.", attemptId: "t-2"))
        XCTAssertNil(action.begin(alert: card, choice: .allow, attemptId: "t-3"))
    }

    func testAnAnswerTheMacAlreadyHandledIsSaidOutLoudAndNotResent() throws {
        let card = try alert(asking())
        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: card, answer: "Yes, go ahead.", attemptId: "t-1"))

        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .refused))
        XCTAssertEqual(action.action?.phase, .refused)
        // A late "couldn't send" must not turn a settled refusal back into an
        // invitation to answer the next question by mistake.
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .failed))
        XCTAssertEqual(action.action?.phase, .refused)
    }

    func testALostReceiptStaysUnknownRatherThanClaimingItFailed() throws {
        let card = try alert(asking())
        var action = WatchSessionActionState()
        let request = try XCTUnwrap(action.begin(alert: card, answer: "Yes, go ahead.",
                                                 attemptId: "t-1"))
        // The message went out and no reply ever came back. "That didn't send"
        // is a claim the wrist cannot make once the message is gone.
        action.lost(attemptId: request.attemptId)
        XCTAssertEqual(action.action?.phase, .unknown)
        // Nothing is resent for it, and nothing is in flight either: the person
        // decides, after looking, whether to answer again.
        XCTAssertFalse(action.isBusy)
        // A late reply cannot reopen a settled ending, in either direction.
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        XCTAssertEqual(action.action?.phase, .unknown)
        action.lost(attemptId: "t-1")
        XCTAssertEqual(action.action?.phase, .unknown)
    }

    func testAnAnswerThatNeverLeftTheWristIsAFailureNotAnUnknown() throws {
        // The two endings support different sentences, which is the whole
        // reason they are two: one may plainly be tried again, the other may
        // only be looked at.
        let card = try alert(asking())
        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: card, answer: "Yes, go ahead.", attemptId: "t-1"))
        action.fail(attemptId: "t-1")
        XCTAssertEqual(action.action?.phase, .failed)
        XCTAssertFalse(action.isBusy)
        // A lost receipt for an attempt we are no longer showing is ignored.
        action.clear()
        action.lost(attemptId: "t-1")
        XCTAssertNil(action.action)
    }

    func testAnAcceptedAnswerWaitsForTheMacAndOnlyASnapshotClearsIt() throws {
        let session = asking()
        let asking = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [session], serverTime: now),
            quotas: [], relay: .live, now: now)
        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: try XCTUnwrap(asking.topAlert),
                                     answer: "Yes, go ahead.", attemptId: "t-1"))
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        XCTAssertEqual(action.action?.phase, .awaitingResolution)

        // The same world again: accepted is not answered, so nothing clears.
        action.reconcile(with: asking)
        XCTAssertEqual(action.action?.phase, .awaitingResolution)

        // A different question on the same session is not this one.
        var moved = session
        moved.pendingQuestion = PendingQuestion(id: "q-2", prompt: "And the title?")
        action.reconcile(with: WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [moved], serverTime: now),
            quotas: [], relay: .live, now: now))
        XCTAssertNil(action.action)
    }

    // MARK: Demo Mode tells the same story

    func testDemoModeOffersBothShapesOfQuestion() throws {
        let state = WatchDemoScenario.question.state(now: now)
        let open = try XCTUnwrap(state.alerts.first { $0.sessionId == "demo-watch-open-question" })
        let withOptions = try XCTUnwrap(state.alerts.first { $0.sessionId == "demo-watch-question" })
        XCTAssertEqual(WatchQuickAnswers.resolve(for: open)?.source, .phrases)
        XCTAssertEqual(WatchQuickAnswers.resolve(for: withOptions)?.source, .options)
        // Both are reachable as a task detail, which is where the wrist opens
        // one from a complication.
        XCTAssertNotNil(WatchDemoScenario.openQuestionTask.task(in: state))
        XCTAssertNotNil(WatchDemoScenario.optionQuestionTask.task(in: state))
        // The open question takes over the home screen.
        XCTAssertEqual(state.topAlert?.sessionId, "demo-watch-open-question")
    }

    func testDemoAnsweringClearsTheQuestionTheWayAMacSnapshotWould() throws {
        let state = WatchDemoScenario.question.state(now: now)
        let alert = try XCTUnwrap(state.topAlert)
        let answered = state.resolvingAnswer(try XCTUnwrap(alert.pendingId))

        XCTAssertFalse(answered.alerts.contains { $0.sessionId == alert.sessionId })
        XCTAssertEqual(answered.counts.needsResponse, state.counts.needsResponse - 1)
        XCTAssertEqual(answered.counts.working, state.counts.working + 1)
        XCTAssertEqual(answered.followedTasks.first { $0.sessionID == alert.sessionId }?.presentation,
                       .thinking)
        // An answer aimed at a question that is not there changes nothing.
        XCTAssertEqual(answered.resolvingAnswer("no-such-question"), answered)

        var action = WatchSessionActionState()
        XCTAssertNotNil(action.begin(alert: alert, answer: "Yes, go ahead.", attemptId: "t-1"))
        action.apply(WatchSessionActionResult(attemptId: "t-1", outcome: .accepted))
        action.reconcile(with: answered)
        XCTAssertNil(action.action, "the next state is what takes the card away")
    }

    // MARK: where the answer is going

    func testTheTargetIsNamedTheSameWayOnBothDevices() {
        let session = asking()
        XCTAssertEqual(SessionActionSupport.targetCaption(macName: "My Mac", session: session),
                       SessionActionSupport.targetCaption(macName: "My Mac",
                                                          project: session.project,
                                                          agent: session.agent))
        XCTAssertEqual(SessionActionSupport.targetCaption(macName: "My Mac", session: session),
                       "My Mac · docs-review · Codex")
        // A relay that never learned the Mac's name still names the project and
        // the agent rather than pretending to know more than it does.
        XCTAssertEqual(SessionActionSupport.targetCaption(macName: nil, project: "docs-review",
                                                          agent: .codex),
                       "Mac · docs-review · Codex")
        XCTAssertEqual(SessionActionSupport.targetCaption(macName: "  ", project: "  ", agent: nil),
                       "Mac · Unknown project")
    }

    func testTheMacsNameTravelsToTheWristButItsAddressDoesNot() throws {
        var state = WatchDemoScenario.question.state(now: now)
        state.macName = "My Mac"
        state.relayRevision = 3
        let payload = try XCTUnwrap(WatchStateInbox.encode(state))
        let json = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(json.contains("My Mac"))
        for secret in ["host", "port", "token", "Bearer"] {
            XCTAssertFalse(json.contains(secret), "the wrist was sent \(secret)")
        }
        // It survives the cache, where it is a label and not a capability.
        let restored = try XCTUnwrap(WatchStoredState.decode(
            try JSONEncoder().encode(WatchStoredState(state: state, queue: WatchCompletionQueue()))))
        XCTAssertEqual(restored.state.macName, "My Mac")
    }
}
