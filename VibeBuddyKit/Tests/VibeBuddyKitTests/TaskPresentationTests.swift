import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Task presentation — Codex Micro status projection")
struct TaskPresentationTests {
    private func session(
        _ id: String,
        status: SessionStatus,
        waitKind: WaitKind? = nil,
        failed: Bool = false,
        unread: Bool = false,
        project: String? = nil,
        updatedAt: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: .codex,
            project: project ?? id,
            status: status,
            waitKind: waitKind,
            failed: failed,
            hasUnreadCompletion: unread,
            statusSince: Date(timeIntervalSince1970: updatedAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    @Test("every lifecycle, wait kind, failure, and unread combination projects by one priority")
    func exhaustiveProjection() {
        let waitKinds: [WaitKind?] = [nil, .permission, .question]
        var combinations = 0

        for status in SessionStatus.allCases {
            for waitKind in waitKinds {
                for failed in [false, true] {
                    for unread in [false, true] {
                        let expected: TaskPresentationState = if failed && status == .done {
                            .error
                        } else {
                            switch status {
                            case .needsResponse: .requiresInput
                            case .working: .thinking
                            case .done: unread ? .completeUnread : .idle
                            }
                        }
                        #expect(session("case-\(combinations)", status: status,
                                        waitKind: waitKind, failed: failed,
                                        unread: unread).presentationState == expected)
                        combinations += 1
                    }
                }
            }
        }

        #expect(combinations == 36)
    }

    @Test("priority is error, input, thinking, unread completion, idle")
    func conflictPriority() {
        #expect(session("failed-wait", status: .needsResponse, waitKind: .permission,
                        failed: true, unread: true).presentationState == .requiresInput)
        #expect(session("wait-unread", status: .needsResponse, waitKind: .question,
                        unread: true).presentationState == .requiresInput)
        #expect(session("work-unread", status: .working,
                        unread: true).presentationState == .thinking)
        #expect(TaskPresentationState.error.attentionRank < TaskPresentationState.requiresInput.attentionRank)
        #expect(TaskPresentationState.requiresInput.attentionRank < TaskPresentationState.thinking.attentionRank)
        #expect(TaskPresentationState.thinking.attentionRank < TaskPresentationState.completeUnread.attentionRank)
        #expect(TaskPresentationState.completeUnread.attentionRank < TaskPresentationState.idle.attentionRank)
    }

    @Test("only terminal failure needs intervention; question and approval precede it")
    func terminalFailureGrouping() {
        let recovering = session("recovering", status: .working, failed: true, updatedAt: 10)
        let failure = session("failed", status: .done, failed: true, updatedAt: 9)
        let approval = session("approval", status: .needsResponse, waitKind: .permission, updatedAt: 8)
        let question = session("question", status: .needsResponse, waitKind: .question, updatedAt: 7)
        var plan = session("plan", status: .needsResponse, waitKind: .permission, updatedAt: 5)
        plan.pendingApproval = PendingApproval(id: "plan-decision", tool: "ExitPlanMode", commandPreview: "Review plan")
        var disconnected = session("disconnected", status: .working, updatedAt: 6)
        disconnected.observations = [.init(source: .rollout,
            lastObservedAt: Date(timeIntervalSince1970: 6), health: .sourceUnreadable)]
        let unread = session("unread", status: .done, unread: true, updatedAt: 3)
        let read = session("read", status: .done, updatedAt: 4)
        let sessions = [recovering, failure, approval, question, plan, disconnected, read, unread]
        let groups = StateGroups(sessions)
        #expect(groups.needsYou.map(\.id) == ["question", "plan", "approval", "failed"])
        #expect(groups.working.map(\.id) == ["recovering", "disconnected"])
        #expect(groups.done.map(\.id) == ["unread", "read"])
        let summary = TaskPresentationSummary(currentIn: sessions, now: Date(timeIntervalSince1970: 11))
        #expect(summary.requiresInput + summary.error == groups.needsYou.count)
        #expect(summary.thinking == groups.working.count)
        #expect(summary.completeUnread + summary.idle == groups.done.count)
    }

    @Test("summary and leading session use the same projection and priority")
    func summaryAndLeading() {
        let sessions = [
            session("idle", status: .done, updatedAt: 9),
            session("complete", status: .done, unread: true, updatedAt: 8),
            session("thinking", status: .working, updatedAt: 7),
            session("input", status: .needsResponse, waitKind: .permission, updatedAt: 6),
            session("error", status: .done, failed: true, updatedAt: 5),
        ]
        let summary = TaskPresentationSummary(sessions: sessions)
        #expect(summary == TaskPresentationSummary(idle: 1, thinking: 1, completeUnread: 1,
                                                   requiresInput: 1, error: 1))
        #expect(summary.primaryState == .error)
        #expect(sessions.leadingPresentationSession?.id == "error")
        #expect(TaskPresentationSummary().primaryState == .unassigned)
        // The snapshot judges currency at `updatedAt`; these rows are seconds old then.
        let snapshot = TaskPresentationSnapshot(sessions: sessions, updatedAt: Date(timeIntervalSince1970: 10))
        #expect(snapshot.summary == summary)
        #expect(snapshot.topSessionId == "error")
    }

    @Test("the two compact slots never say the same thing")
    func compactSlotsCarryStateAndCount() {
        let sessions = [
            session("idle", status: .done, updatedAt: 9),
            session("thinking", status: .working, updatedAt: 7),
            session("input", status: .needsResponse, waitKind: .permission, updatedAt: 6),
            session("error", status: .done, failed: true, project: "build-fail", updatedAt: 5),
        ]
        let leading = sessions.leadingPresentationSession
        let summary = TaskPresentationSummary(sessions: sessions)
        #expect(leading?.id == "error")
        // compactLeading draws this state; compactTrailing draws its count.
        #expect(summary.primaryState == .error)
        #expect(LiveActivityPresentation.compactTrailingCount(summary: summary) == 1)
        #expect(LiveActivityPresentation.compactAccessibilityLabel(
            project: leading?.project, state: .error) == "build-fail, \(TaskPresentationState.error.label)")
        #expect(LiveActivityPresentation.compactTrailingAccessibilityLabel(
            summary: summary) == "1 \(TaskPresentationState.error.label)")
    }

    @Test("the island count is the Glance count, so both surfaces say the same number")
    func compactTrailingMatchesGlanceGrammar() {
        // ADR-0011: the compact count follows the primary state's own group.
        for summary in [
            TaskPresentationSummary(idle: 4, thinking: 3, requiresInput: 2),
            TaskPresentationSummary(thinking: 3, completeUnread: 5),
            TaskPresentationSummary(idle: 7),
            TaskPresentationSummary(thinking: 2, error: 1),
        ] {
            #expect(LiveActivityPresentation.compactTrailingCount(summary: summary)
                    == summary.count(for: summary.primaryState))
            #expect(LiveActivityPresentation.compactTrailingAccessibilityLabel(summary: summary)
                    == "\(summary.count(for: summary.primaryState)) \(summary.primaryState.label)")
        }

        // The pill caps at 99+, but VoiceOver keeps the exact count.
        let crowded = TaskPresentationSummary(thinking: 120)
        #expect(LiveActivityPresentation.compactTrailingCount(summary: crowded) == 120)
        #expect(LiveActivityPresentation.compactTrailingAccessibilityLabel(
            summary: crowded) == "120 \(TaskPresentationState.thinking.label)")
    }
}
