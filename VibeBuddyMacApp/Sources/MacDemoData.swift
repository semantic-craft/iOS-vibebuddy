import Foundation
import VibeBuddyKit

/// Sample sessions for screenshots / exploration, gated behind `VIBEBUDDY_DEMO=1`.
/// A demo instance seeds these and skips the server/polling entirely, so it never
/// binds the port, pushes to a phone, or touches real session data (privacy-safe).
enum MacDemoData {
    static func observationDiagnostics(now: Date = Date()) -> [AgentObservationDiagnostic] {
        [
            AgentObservationDiagnostic(agent: .claudeCode, sources: [
                ObservationSourceDiagnostic(
                    source: .hook, health: .healthy,
                    lastObservedAt: now.addingTimeInterval(-8),
                    configuredCoverage: ObservationEventCoverage.allCases,
                    observedCoverage: [.lifecycle, .turn, .tool, .attention]),
                ObservationSourceDiagnostic(
                    source: .transcript, health: .healthy,
                    lastObservedAt: now.addingTimeInterval(-8),
                    observedCoverage: [.turn]),
            ]),
            AgentObservationDiagnostic(agent: .codex, sources: [
                ObservationSourceDiagnostic(
                    source: .hook, health: .eventsMissing,
                    configuredCoverage: [.lifecycle, .turn]),
                ObservationSourceDiagnostic(
                    source: .rollout, health: .temporarilySilent,
                    lastObservedAt: now.addingTimeInterval(-12 * 60),
                    observedCoverage: [.turn, .tool]),
            ]),
        ]
    }

    static func sessions(now: Date = Date()) -> [AgentSession] {
        [
            // ── Needs response ──────────────────────────────────────────────
            AgentSession(
                id: "demo-edit", agent: .claudeCode, project: "todo-app", branch: "feat/reminders",
                model: "claude-opus-4-8", status: .needsResponse, waitKind: .permission,
                pendingApproval: PendingApproval(
                    id: "demo-ap", tool: "Edit", commandPreview: "src/reminders.ts",
                    filePath: "src/reminders.ts",
                    oldText: "todos.sort((a, b) => a.id - b.id)",
                    newText: "todos.sort((a, b) => a.dueDate - b.dueDate)"),
                summary: "Sort reminders by due date",
                tokens: 4200, contextTokens: 128_000, contextWindow: 200_000,
                observations: [ObservationEvidence(
                    source: .hook, lastObservedAt: now.addingTimeInterval(-44), health: .healthy)],
                statusSince: now.addingTimeInterval(-44), updatedAt: now.addingTimeInterval(-44)),
            AgentSession(
                id: "demo-question", agent: .claudeCode, project: "docs-review", branch: "main",
                model: "claude-sonnet-4-5", status: .needsResponse, waitKind: .question,
                pendingQuestion: PendingQuestion(
                    id: "tone",
                    prompt: "Which revision style should I use?",
                    options: [
                        QuestionOption(id: "tight", label: "Tighten", value: "Tighten the draft without changing the argument."),
                        QuestionOption(id: "plain", label: "Plain language", value: "Make it plainer and keep the citations intact."),
                    ]),
                summary: "Which revision style should I use?",
                tokens: 2100, contextTokens: 92_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-28), updatedAt: now.addingTimeInterval(-28)),

            // ── Working ─────────────────────────────────────────────────────
            AgentSession(
                id: "demo-work-1", agent: .codex, project: "api-gateway", branch: "main",
                model: "gpt-5-codex", status: .working, summary: "Running the test suite…",
                tokens: 1500, contextTokens: 64_000, contextWindow: 200_000,
                activeTool: "Bash",
                observations: [ObservationEvidence(
                    source: .rollout, lastObservedAt: now.addingTimeInterval(-9), health: .healthy)],
                statusSince: now.addingTimeInterval(-9), updatedAt: now.addingTimeInterval(-9)),
            AgentSession(
                id: "demo-work-2", agent: .claudeCode, project: "web-dashboard", branch: "feat/auth",
                model: "claude-opus-4-8", status: .working, summary: "Refactoring the auth middleware…",
                tokens: 6300, contextTokens: 151_000, contextWindow: 200_000,
                activeTool: "Edit",
                childAgents: [
                    ChildAgent(id: "subagent:demo-explore", kind: .subagent, name: "Explore",
                               status: .running, lastActivity: "Grep",
                               updatedAt: now.addingTimeInterval(-12)),
                    ChildAgent(id: "task:demo-auth", kind: .task, name: "implementer",
                               type: "implementer", status: .running,
                               lastActivity: "Implement auth",
                               updatedAt: now.addingTimeInterval(-9)),
                ],
                statusSince: now.addingTimeInterval(-15), updatedAt: now.addingTimeInterval(-15)),
            AgentSession(
                id: "demo-work-3", agent: .grok, project: "glaux-book", branch: "main",
                model: "grok-4.6", status: .working, summary: "Running the build script…",
                tokens: 2800, contextTokens: 96_000, contextWindow: 500_000,
                activeTool: "run_terminal_command",
                observations: [ObservationEvidence(
                    source: .hook, lastObservedAt: now.addingTimeInterval(-6), health: .healthy)],
                statusSince: now.addingTimeInterval(-6), updatedAt: now.addingTimeInterval(-6)),

            // ── Done ────────────────────────────────────────────────────────
            AgentSession(
                id: "demo-done-1", agent: .codex, project: "payments-api", branch: "main",
                model: "gpt-5-codex", status: .done, summary: "All tests green — 142 passed.",
                tokens: 5400, contextTokens: 78_000, contextWindow: 200_000,
                hasUnreadCompletion: true,
                statusSince: now.addingTimeInterval(-180), updatedAt: now.addingTimeInterval(-180)),
            AgentSession(
                id: "demo-done-2", agent: .claudeCode, project: "docs-site", branch: "main",
                model: "claude-haiku-4-5", status: .done, summary: "Idle — no unread updates.",
                tokens: 900, contextTokens: 20_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-320), updatedAt: now.addingTimeInterval(-320)),
            AgentSession(
                id: "demo-error", agent: .codex, project: "release-check", branch: "main",
                model: "gpt-5-codex", status: .done, summary: "Build failed with two signing errors.",
                tokens: 3100, contextTokens: 48_000, contextWindow: 200_000,
                failed: true,
                statusSince: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-120)),
        ]
    }
}
