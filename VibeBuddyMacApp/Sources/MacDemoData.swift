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
                // iTerm2 with a captured session id — the most precise jump there is.
                terminalRef: TerminalRef(termProgram: "iTerm.app", tty: "ttys004",
                                         itermSessionId: "9F2C41A0-5B7E-4E1D-8C3A-1D0E77B26F44",
                                         hostBundleId: "com.googlecode.iterm2", hostPid: 2841,
                                         cwd: "/Users/xw/Projects/todo-app"),
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
                // Ghostty: no env var for the surface, so the id was probed at
                // SessionStart and the cwd is the fallback match.
                terminalRef: TerminalRef(termProgram: "ghostty", ghosttyTerminalId: "17",
                                         hostBundleId: "com.mitchellh.ghostty", hostPid: 3102,
                                         cwd: "/Users/xw/Projects/docs-review"),
                summary: "Which revision style should I use?",
                tokens: 2100, contextTokens: 92_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-28), updatedAt: now.addingTimeInterval(-28)),

            // ── Working ─────────────────────────────────────────────────────
            AgentSession(
                id: "demo-work-1", agent: .codex, project: "api-gateway", branch: "main",
                model: "gpt-5-codex", status: .working,
                // tmux inside iTerm2: the pane is selected first, then the tab raised.
                terminalRef: TerminalRef(termProgram: "iTerm.app", tty: "ttys011",
                                         tmux: "/private/tmp/tmux-501/default,914,0", tmuxPane: "%3",
                                         hostBundleId: "com.googlecode.iterm2", hostPid: 2841,
                                         cwd: "/Users/xw/Projects/api-gateway"),
                summary: "Running the test suite…",
                tokens: 1500, contextTokens: 64_000, contextWindow: 200_000,
                activeTool: "Bash",
                observations: [ObservationEvidence(
                    source: .rollout, lastObservedAt: now.addingTimeInterval(-9), health: .healthy)],
                statusSince: now.addingTimeInterval(-9), updatedAt: now.addingTimeInterval(-9)),
            AgentSession(
                id: "demo-work-2", agent: .claudeCode, project: "web-dashboard", branch: "feat/auth",
                model: "claude-opus-4-8", status: .working,
                // Claude desktop: no TERM_PROGRAM at all, so only the host app is
                // known and a jump can honestly promise no more than that.
                terminalRef: TerminalRef(hostBundleId: "com.anthropic.claude-code", hostPid: 4507,
                                         cwd: "/Users/xw/Projects/web-dashboard"),
                summary: "Refactoring the auth middleware…",
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

            // ── Done ────────────────────────────────────────────────────────
            AgentSession(
                id: "demo-done-1", agent: .codex, project: "payments-api", branch: "main",
                model: "gpt-5-codex", status: .done,
                // Terminal.app exposes a per-tab tty, which is an exact target.
                terminalRef: TerminalRef(termProgram: "apple_terminal", tty: "ttys002",
                                         hostBundleId: "com.apple.Terminal", hostPid: 1990,
                                         cwd: "/Users/xw/Projects/payments-api"),
                summary: "All tests green — 142 passed.",
                tokens: 5400, contextTokens: 78_000, contextWindow: 200_000,
                hasUnreadCompletion: true,
                statusSince: now.addingTimeInterval(-180), updatedAt: now.addingTimeInterval(-180)),
            AgentSession(
                id: "demo-done-2", agent: .claudeCode, project: "docs-site", branch: "main",
                model: "claude-haiku-4-5", status: .done,
                // Deliberately left without a ref: the "no terminal recorded"
                // state has to be visible in the demo too.
                summary: "Idle — no unread updates.",
                tokens: 900, contextTokens: 20_000, contextWindow: 200_000,
                statusSince: now.addingTimeInterval(-320), updatedAt: now.addingTimeInterval(-320)),
            AgentSession(
                id: "demo-error", agent: .codex, project: "release-check", branch: "main",
                model: "gpt-5-codex", status: .done,
                // VS Code's integrated terminal exposes no addressable surface —
                // app level is the ceiling.
                terminalRef: TerminalRef(termProgram: "vscode",
                                         hostBundleId: "com.microsoft.VSCode", hostPid: 5210,
                                         cwd: "/Users/xw/Projects/release-check"),
                summary: "Build failed with two signing errors.",
                tokens: 3100, contextTokens: 48_000, contextWindow: 200_000,
                failed: true,
                statusSince: now.addingTimeInterval(-120), updatedAt: now.addingTimeInterval(-120)),
        ]
    }
}
