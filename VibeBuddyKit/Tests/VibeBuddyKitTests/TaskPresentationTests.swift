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
        updatedAt: TimeInterval = 0
    ) -> AgentSession {
        AgentSession(
            id: id,
            agent: .codex,
            project: id,
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
                        let expected: TaskPresentationState = if failed {
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
                        failed: true, unread: true).presentationState == .error)
        #expect(session("wait-unread", status: .needsResponse, waitKind: .question,
                        unread: true).presentationState == .requiresInput)
        #expect(session("work-unread", status: .working,
                        unread: true).presentationState == .thinking)
        #expect(TaskPresentationState.error.attentionRank < TaskPresentationState.requiresInput.attentionRank)
        #expect(TaskPresentationState.requiresInput.attentionRank < TaskPresentationState.thinking.attentionRank)
        #expect(TaskPresentationState.thinking.attentionRank < TaskPresentationState.completeUnread.attentionRank)
        #expect(TaskPresentationState.completeUnread.attentionRank < TaskPresentationState.idle.attentionRank)
    }

    @Test("exact implementation color tokens stay centralized")
    func tokens() {
        #expect(TaskPresentationState.idle.colorToken.hex == "#FFFFFF")
        #expect(TaskPresentationState.thinking.colorToken.hex == "#304FFE")
        #expect(TaskPresentationState.completeUnread.colorToken.hex == "#00FF4C")
        #expect(TaskPresentationState.requiresInput.colorToken.hex == "#FF6D00")
        #expect(TaskPresentationState.error.colorToken.hex == "#FF0033")
        #expect(TaskPresentationState.unassigned.colorToken.hex == "#000000")
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
        #expect(TaskPresentationSnapshot(sessions: sessions).summary == summary)
        #expect(TaskPresentationSnapshot(sessions: sessions).topSessionId == "error")
    }
}
