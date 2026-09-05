import Foundation
import VibeBuddyKit

/// Holds a question the agent is waiting on — Claude's blocking
/// `AskUserQuestion` hook, Codex's `request_user_input` server request — until
/// an answer arrives (`/answer`, the Mac card, the voice companion) or the wait
/// times out. Keyed by session: one question is open per session at a time,
/// which is also what the card shows.
public actor QuestionRegistry {
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<QuestionAnswers?, Never>
    }

    private var waiters: [String: Waiter] = [:]
    private var early: [String: QuestionAnswers] = [:]

    public init() {}

    /// Whether an agent is waiting on this session right now, so a caller can
    /// choose between resolving a wait and typing into a terminal.
    public func isWaiting(sessionID: String) -> Bool { waiters[sessionID] != nil }

    public func wait(sessionID: String, timeout: Duration) async -> QuestionAnswers? {
        if let answers = early.removeValue(forKey: sessionID) { return answers }
        let token = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<QuestionAnswers?, Never>) in
            // A newer question on the same session supersedes the old wait.
            waiters[sessionID]?.continuation.resume(returning: nil)
            waiters[sessionID] = Waiter(token: token, continuation: cont)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.expire(sessionID: sessionID, token: token)
            }
        }
    }

    /// Deliver answers. Returns false when nothing was waiting; the answers are
    /// then kept briefly for a wait that is about to register (the card is
    /// broadcast an actor hop before the hook route starts waiting).
    @discardableResult
    public func resolve(sessionID: String, answers: QuestionAnswers) -> Bool {
        if let waiter = waiters.removeValue(forKey: sessionID) {
            waiter.continuation.resume(returning: answers)
            return true
        }
        early[sessionID] = answers
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            await self?.forgetEarly(sessionID: sessionID)
        }
        return false
    }

    /// The agent resolved or dropped the question elsewhere: stop waiting.
    public func cancel(sessionID: String) {
        waiters.removeValue(forKey: sessionID)?.continuation.resume(returning: nil)
    }

    private func expire(sessionID: String, token: UUID) {
        // Only the wait that installed this timer expires; a newer wait for the
        // same session keeps its own.
        guard let waiter = waiters[sessionID], waiter.token == token else { return }
        waiters.removeValue(forKey: sessionID)
        waiter.continuation.resume(returning: nil)
    }

    private func forgetEarly(sessionID: String) { early[sessionID] = nil }
}

/// Where a phone or Mac answer goes: to the agent waiting on it through its
/// own contract when it is, else typed into the session's terminal (tmux only),
/// else nowhere — the caller reports "not delivered".
public struct AnswerDispatch: Sendable {
    public let store: SessionStore
    public let questions: QuestionRegistry
    public let inject: @Sendable (TerminalRef, String) -> Void
    /// Codex: put free text into the thread through the app-server daemon
    /// (`turn/steer` while a turn runs, `turn/start` when idle). Arguments:
    /// thread id, text, whether the session is currently active.
    public let steer: @Sendable (String, String, Bool) async -> Bool

    public init(store: SessionStore, questions: QuestionRegistry,
                inject: @escaping @Sendable (TerminalRef, String) -> Void,
                steer: @escaping @Sendable (String, String, Bool) async -> Bool = { _, _, _ in false }) {
        self.store = store
        self.questions = questions
        self.inject = inject
        self.steer = steer
    }

    /// `answers` are keyed by question id; `text` is a plain reply (voice, an
    /// older phone build). Either fills the other in.
    @discardableResult
    public func deliver(sessionID: String, text: String?, answers: QuestionAnswers?) async -> Bool {
        let session = await store.snapshot(now: Date()).sessions.first { $0.id == sessionID }
        let pending = session?.pendingQuestion
        let structured = Self.normalize(answers: answers, text: text, for: pending)
        if !structured.isEmpty, await questions.isWaiting(sessionID: sessionID) {
            await questions.resolve(sessionID: sessionID, answers: structured)
            return true
        }
        let typed = text ?? Self.flatten(structured)
        guard !typed.isEmpty else { return false }
        if session?.agent == .codex {
            // Codex threads take instructions through the daemon, never through
            // a terminal: the thread may live in Desktop, and typing into a
            // pane cannot address a specific thread anyway.
            let active = session.map { $0.status != .done } ?? false
            guard await steer(sessionID, typed, active) else { return false }
            await store.endQuestion(sessionID: sessionID, at: Date())
            return true
        }
        guard let ref = await store.terminalRef(for: sessionID) else { return false }
        inject(ref, typed)
        await store.endQuestion(sessionID: sessionID, at: Date())
        return true
    }

    /// A plain text answer maps onto the first question; structured answers
    /// pass through.
    static func normalize(answers: QuestionAnswers?, text: String?, for pending: PendingQuestion?) -> QuestionAnswers {
        if let answers, !answers.isEmpty { return answers }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [:] }
        let id = pending?.items.first?.id ?? pending?.id ?? "question"
        return [id: [text]]
    }

    static func flatten(_ answers: QuestionAnswers) -> String {
        answers.keys.sorted().compactMap { key in
            let values = answers[key] ?? []
            return values.isEmpty ? nil : values.joined(separator: ", ")
        }.joined(separator: "\n")
    }
}
