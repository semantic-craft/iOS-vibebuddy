import Foundation
import VibeBuddyKit

/// Sample sessions for screenshots / exploration, gated behind `VIBEBUDDY_DEMO=1`.
/// A demo instance seeds these and skips the server/polling entirely, so it never
/// binds the port, pushes to a phone, or touches real session data (privacy-safe).
enum MacDemoData {
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
                statusSince: now.addingTimeInterval(-9), updatedAt: now.addingTimeInterval(-9)),
            AgentSession(
                id: "demo-work-2", agent: .claudeCode, project: "web-dashboard", branch: "feat/auth",
                model: "claude-opus-4-8", status: .working, summary: "Refactoring the auth middleware…",
                tokens: 6300, contextTokens: 151_000, contextWindow: 200_000,
                activeTool: "Edit",
                statusSince: now.addingTimeInterval(-15), updatedAt: now.addingTimeInterval(-15)),

            // ── Done ────────────────────────────────────────────────────────
            AgentSession(
                id: "demo-done-1", agent: .codex, project: "payments-api", branch: "main",
                model: "gpt-5-codex", status: .done, summary: "All tests green — 142 passed.",
                tokens: 5400, contextTokens: 78_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-180), updatedAt: now.addingTimeInterval(-180)),
            AgentSession(
                id: "demo-done-2", agent: .claudeCode, project: "docs-site", branch: "main",
                model: "claude-haiku-4-5", status: .done, summary: "Deployed to production.",
                tokens: 900, contextTokens: 20_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-320), updatedAt: now.addingTimeInterval(-320)),
        ]
    }
}
