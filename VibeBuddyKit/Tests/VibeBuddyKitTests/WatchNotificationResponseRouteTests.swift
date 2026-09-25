import Foundation
import Testing
@testable import VibeBuddyKit

/// The routing decision behind the Watch's notification-centre delegate: which
/// tap opens, which acts, and which does nothing — without a notification.
struct WatchNotificationResponseRouteTests {
    private func resolve(_ action: NotificationActionID?, dismiss: Bool = false,
                         session: String? = "s-build", approval: String? = "ap-1",
                         question: String? = nil,
                         text: String? = nil) -> WatchNotificationResponseRoute {
        WatchNotificationResponseRoute.resolve(action: action, isDismiss: dismiss,
                                               sessionID: session, approvalID: approval,
                                               questionID: question, userText: text)
    }

    @Test func theDefaultTapOpensTheSession() {
        #expect(resolve(nil) == .open(sessionID: "s-build"))
        #expect(resolve(nil).isAction == false)
    }

    @Test func approveAndDenyBindToTheApprovalTheyCameWith() {
        #expect(resolve(.approve) == .decide(sessionID: "s-build", approvalID: "ap-1", choice: .allow))
        #expect(resolve(.deny) == .decide(sessionID: "s-build", approvalID: "ap-1", choice: .deny))
        #expect(resolve(.approve).isAction)
    }

    @Test func aDecisionWithoutAnApprovalIdOnlyOpens() {
        #expect(resolve(.approve, approval: nil) == .open(sessionID: "s-build"))
        #expect(resolve(.deny, approval: "  ") == .open(sessionID: "s-build"))
    }

    @Test func aReplyCarriesItsTrimmedTextOrOpens() {
        #expect(resolve(.answer, text: "  ship it \n")
                == .answer(sessionID: "s-build", questionID: nil, text: "ship it"))
        #expect(resolve(.answer, text: "   ") == .open(sessionID: "s-build"))
        #expect(resolve(.answer, text: nil) == .open(sessionID: "s-build"))
    }

    @Test func aReplyCarriesTheQuestionItsNotificationNamed() {
        #expect(resolve(.answer, question: " q-7 ", text: "no")
                == .answer(sessionID: "s-build", questionID: "q-7", text: "no"))
        // An older sender's cue names none: the reply still goes, unbound.
        #expect(resolve(.answer, question: "  ", text: "no")
                == .answer(sessionID: "s-build", questionID: nil, text: "no"))
        // A question id never turns a decision or a default tap into a reply.
        #expect(resolve(.approve, question: "q-7") == .decide(sessionID: "s-build", approvalID: "ap-1",
                                                               choice: .allow))
        #expect(resolve(nil, question: "q-7") == .open(sessionID: "s-build"))
    }

    @Test func dismissAndMissingSessionAreNotRequests() {
        #expect(resolve(.approve, dismiss: true) == .ignore)
        #expect(resolve(nil, session: nil) == .ignore)
        #expect(resolve(.approve, session: "") == .ignore)
        #expect(resolve(nil, session: nil).sessionID == nil)
    }
}

/// When a state that does not hold the tapped request is allowed to end the
/// hold — the rule that decides whether a banner Approve reaches the Mac or is
/// abandoned with "this is no longer waiting on you".
struct WatchBannerActionPatienceTests {
    private let route = WatchNotificationResponseRoute.decide(sessionID: "s-build",
                                                              approvalID: "ap-1", choice: .allow)

    @Test func theSameRevisionComingBackIsNotEvidenceTheRequestIsGone() {
        // The R6/R8 shape: the approval is newer than anything the wrist holds,
        // and activation re-delivers the pre-tap context moments after launch.
        // `WatchStateInbox.accept` takes an equal revision back, so this is a
        // real install — and it must not end the hold.
        var held = WatchBannerAction(route: route, baselineRevision: 12)
        held.noteInstalled(revision: 12)
        #expect(held.provesRequestGone(currentRevision: 12) == false)
    }

    @Test func theFirstEvidenceStateIsTheBaselineAndProvesNothing() {
        // A hold starts with no mark at all. Whatever was on screen at the tap
        // is the cache (ids stripped) or a context taken while the relay was
        // down, and a mark read off either makes the first honest live snapshot
        // — newer than the cache, and not yet carrying an approval still in
        // flight — look like proof the request ended. The store seeds nothing;
        // the first state it accepts as evidence is the mark, and that one
        // answers nothing by itself.
        var held = WatchBannerAction(route: route)
        #expect(held.baselineRevision == nil)
        #expect(held.provesRequestGone(currentRevision: 40) == false)
        held.noteInstalled(revision: 40)
        #expect(held.baselineRevision == 40)
        #expect(held.provesRequestGone(currentRevision: 40) == false)
        #expect(held.provesRequestGone(currentRevision: 41))
    }

    @Test func theBaselineNeverMoves() {
        var held = WatchBannerAction(route: route, baselineRevision: 7)
        held.noteInstalled(revision: 8)
        held.noteInstalled(revision: 9)
        #expect(held.baselineRevision == 7)
        #expect(held.provesRequestGone(currentRevision: 8))
    }

    @Test func runningOutOfPatienceIsNotProofTheRequestEnded() {
        // The wrist gave up waiting; that is not the same as learning the
        // request left, and the card must not claim it was. The store picks the
        // honest sentence — this only refuses to hand it the wrong one.
        let held = WatchBannerAction(route: route, baselineRevision: 12)
        #expect(held.provesRequestGone(currentRevision: 12) == false)
        #expect(held.provesRequestGone(currentRevision: nil) == false)
    }
}

/// Which question a dictated reply belongs to when its notification named none
/// (an older phone or Mac): a held reply that followed the session would answer
/// whatever was being asked by the time it travelled.
struct WatchBannerActionAnswerBindingTests {
    private let route = WatchNotificationResponseRoute.answer(sessionID: "s-build", questionID: nil,
                                                              text: "no")

    @Test func aQuestionThatMovedOnIsNotThisReplysQuestion() {
        // "No" to "Delete the database?" must not be recorded against "Ship the
        // release?" — which the iPhone's gate would accept, because that id is
        // the live one.
        var held = WatchBannerAction(route: route)
        let first = held.bindsAnswer(to: "q-1")
        #expect(first)
        let moved = held.bindsAnswer(to: "q-2")
        #expect(moved == false)
        // And the refusal is stable: the binding does not follow on a retry.
        let retried = held.bindsAnswer(to: "q-2")
        #expect(retried == false)
        #expect(held.boundPendingID == "q-1")
    }

    @Test func aStateWithNoQuestionIdBindsNothingAndSendsNothing() {
        var held = WatchBannerAction(route: route)
        let none = held.bindsAnswer(to: nil)
        #expect(none == false)
        let blank = held.bindsAnswer(to: "   ")
        #expect(blank == false)
        #expect(held.boundPendingID == nil)
        // A later state that does name one is still free to bind it.
        let named = held.bindsAnswer(to: "q-1")
        #expect(named)
        #expect(held.boundPendingID == "q-1")
    }
}

/// A reply whose notification named its question (`questionId`, #248) is bound
/// the moment it is held, and `replyStanding` decides where the words may go —
/// the pure half of `WatchStateStore.settleBannerAction`.
struct WatchBannerReplyStandingTests {
    private func question(_ pendingID: String?, session: String = "s-build",
                          walked: Bool = false) -> WatchAlert {
        WatchAlert(sessionId: session, agent: .claudeCode, project: "vibebuddy", waitKind: .question,
                   request: "Delete the database?", pendingId: pendingID,
                   questions: walked ? [WatchQuestionItem(id: "a", text: "Which?", options: [])] : nil,
                   handling: .remoteAvailable, waitingSince: Date(timeIntervalSince1970: 0))
    }

    private func standing(bound: String?, _ alerts: [WatchAlert]) -> WatchBannerAction.ReplyStanding {
        WatchBannerAction.replyStanding(boundPendingID: bound, sessionID: "s-build", alerts: alerts)
    }

    @Test func aNamedQuestionIsBoundAtTheHoldAndNoStateMovesIt() {
        var held = WatchBannerAction(route: .answer(sessionID: "s-build", questionID: "q-2", text: "no"))
        #expect(held.boundPendingID == "q-2")
        // The first relayed state after a cold launch may still show the
        // previous question. First sight used to bind to it; now it is refused.
        let firstSight = held.bindsAnswer(to: "q-1")
        #expect(firstSight == false)
        #expect(held.boundPendingID == "q-2")
        let own = held.bindsAnswer(to: "q-2")
        #expect(own)
    }

    @Test func anUnnamedReplyStillBindsAtFirstSight() {
        let held = WatchBannerAction(route: .answer(sessionID: "s-build", questionID: nil, text: "no"))
        #expect(held.boundPendingID == nil)
        #expect(standing(bound: nil, [question("q-1")]) == .asking(question("q-1")))
    }

    @Test func theBoundQuestionIsTheOneAnswered() {
        let other = question("q-9", session: "s-other")
        #expect(standing(bound: "q-2", [other, question("q-2")]) == .asking(question("q-2")))
    }

    @Test func aQuestionThatChangedBetweenDictationAndSendIsRefused() {
        // "No" to "Delete the database?" must not reach "Ship the release?".
        #expect(standing(bound: "q-1", [question("q-2")]) == .replaced)
    }

    @Test func aPromptWithNoIdCannotBeAnsweredFromTheBanner() {
        // Id-less on the wrist: part of it must be typed. It may be the bound
        // question itself (the Mac names it, the wrist drops the id), so it is
        // "decide it elsewhere", never "no longer waiting".
        #expect(standing(bound: "q-1", [question(nil)]) == .unbindable(question(nil)))
        #expect(standing(bound: nil, [question("  ")]) == .unbindable(question("  ")))
    }

    @Test func aWalkedPromptIsFoundSoTheCallerCanSendItToTheCard() {
        // Multi-part: found by its id, then refused by `isAnswerableInOneString`
        // — the card's question-by-question walk is the way to answer it.
        let walked = question("q-1", walked: true)
        #expect(standing(bound: "q-1", [walked]) == .asking(walked))
        #expect(walked.isAnswerableInOneString == false)
    }

    @Test func aSessionAskingNothingIsAbsent() {
        #expect(standing(bound: "q-1", []) == .absent)
        #expect(standing(bound: nil, [question("q-1", session: "s-other")]) == .absent)
    }
}


/// When the words of a refused banner reply may leave the card, and when the
/// words of a sent one come back to it.
struct WatchUnsentReplyTests {
    private func attempt(_ id: String, _ phase: WatchSessionActionAttempt.Phase,
                         session: String = "s-build") -> WatchSessionActionAttempt {
        WatchSessionActionAttempt(attemptId: id, sessionId: session,
                                  action: .answer(pendingId: "q-1", text: "yes"), phase: phase)
    }

    @Test func anEarlierAnswerRepublishedUnchangedDoesNotWipeTheWords() {
        // The card answered q-1 (X, awaiting), the banner reply for q-2 was
        // refused while X was in flight, then an install re-publishes X as is.
        let unsent = WatchUnsentReply(sessionID: "s-build", text: "no", attemptID: "X")
        #expect(unsent.isSuperseded(from: attempt("X", .awaitingResolution),
                                    to: attempt("X", .awaitingResolution)) == false)
        // Even a phase change of that earlier attempt is not about these words.
        #expect(unsent.isSuperseded(from: attempt("X", .sending), to: attempt("X", .queued)) == false)
        // An install with nothing in flight before either.
        let none = WatchUnsentReply(sessionID: "s-build", text: "no", attemptID: nil)
        #expect(none.isSuperseded(from: attempt("X", .awaitingResolution),
                                  to: attempt("X", .awaitingResolution)) == false)
    }

    @Test func aLaterAnswerThatTravelledSupersedesTheWords() {
        let unsent = WatchUnsentReply(sessionID: "s-build", text: "no", attemptID: "X")
        #expect(unsent.isSuperseded(from: attempt("Y", .sending), to: attempt("Y", .awaitingResolution)))
        #expect(unsent.isSuperseded(from: attempt("X", .awaitingResolution), to: attempt("Y", .queued)))
        // Not while it is still travelling, not when it failed, not another session.
        #expect(unsent.isSuperseded(from: nil, to: attempt("Y", .sending)) == false)
        #expect(unsent.isSuperseded(from: attempt("Y", .sending), to: attempt("Y", .failed)) == false)
        #expect(unsent.isSuperseded(from: nil, to: attempt("Y", .awaitingResolution, session: "s-other")) == false)
    }

    @Test func aSentReplyThatSaidNothingComesBack() {
        let sent = WatchUnsentReply(sessionID: "s-build", text: "no", attemptID: "Y")
        #expect(sent.restored(by: attempt("Y", .refused)) == sent)
        #expect(sent.restored(by: attempt("Y", .failed)) == sent)
        // The Mac may have it, or does: never offered for sending again.
        #expect(sent.restored(by: attempt("Y", .unknown)) == nil)
        #expect(sent.restored(by: attempt("Y", .awaitingResolution)) == nil)
        #expect(sent.restored(by: attempt("Z", .refused)) == nil)
        // A restored reply can never be superseded by the attempt that failed.
        #expect(sent.isSuperseded(from: nil, to: attempt("Y", .awaitingResolution)) == false)
    }
}
