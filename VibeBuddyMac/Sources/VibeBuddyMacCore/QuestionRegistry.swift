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

/// Recent `/answer` request ids, so a duplicate tap returns the first result
/// instead of running the action twice. Lost after a daemon restart — the
/// client must then show unknown, not claim exactly-once.
public actor ActionRequestLog {
    private var seen: [String: SessionActionDelivery] = [:]
    private var order: [String] = []
    private let limit = 64

    public init() {}

    public func recall(_ id: String) -> SessionActionDelivery? { seen[id] }

    public func remember(_ id: String, _ result: SessionActionDelivery) {
        if seen[id] == nil { order.append(id) }
        seen[id] = result
        while order.count > limit {
            seen.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Daemon-side result of one session action. The phone maps this onto
/// `SessionActionOutcome` (adding not-sent / unknown around the transport).
public enum SessionActionDelivery: Equatable, Sendable {
    case accepted
    case failed(String)
}

/// Where a phone or Mac action goes: to the waiting agent through its own
/// contract, else Codex `turn/steer` / `turn/start` by intent, else a tmux
/// pane for an old no-intent Claude reply. Steer never becomes start.
public struct AnswerDispatch: Sendable {
    public let store: SessionStore
    public let questions: QuestionRegistry
    public let inject: @Sendable (TerminalRef, String) -> Void
    /// Codex `turn/steer` only. False when the daemon refused or there is no
    /// connection — the caller must not start a turn.
    public let steer: @Sendable (String, String) async -> Bool
    /// Codex `turn/start` (resume first when the thread is cold).
    public let startTurn: @Sendable (String, String) async -> Bool
    public let requests: ActionRequestLog

    public init(store: SessionStore, questions: QuestionRegistry,
                inject: @escaping @Sendable (TerminalRef, String) -> Void,
                steer: @escaping @Sendable (String, String) async -> Bool = { _, _ in false },
                startTurn: @escaping @Sendable (String, String) async -> Bool = { _, _ in false },
                requests: ActionRequestLog = ActionRequestLog()) {
        self.store = store
        self.questions = questions
        self.inject = inject
        self.steer = steer
        self.startTurn = startTurn
        self.requests = requests
    }

    /// Older callers: infer intent from the live session and return whether
    /// anything was delivered.
    @discardableResult
    public func deliver(sessionID: String, text: String?, answers: QuestionAnswers?) async -> Bool {
        let result = await deliver(SessionActionRequest(sessionID: sessionID, text: text, answers: answers))
        if case .accepted = result { return true }
        return false
    }

    public func deliver(_ request: SessionActionRequest) async -> SessionActionDelivery {
        if let prior = await requests.recall(request.requestID) { return prior }
        let result = await execute(request)
        await requests.remember(request.requestID, result)
        return result
    }

    private func execute(_ request: SessionActionRequest) async -> SessionActionDelivery {
        let session = await store.snapshot(now: Date()).sessions.first { $0.id == request.sessionID }
        let pending = session?.pendingQuestion
        let waiting = await questions.isWaiting(sessionID: request.sessionID)
        let structured = Self.normalize(answers: request.answers, text: request.text, for: pending)
        let typed = request.text ?? Self.flatten(structured)
        let intent = request.intent ?? inferredIntent(session: session, waiting: waiting, pending: pending)

        if intent == .answer {
            if let questionID = request.questionID, let pending,
               pending.id != questionID, !pending.items.contains(where: { $0.id == questionID }) {
                return .failed("This question is no longer waiting")
            }
            guard waiting, !structured.isEmpty else {
                return .failed("This question is no longer waiting")
            }
            await questions.resolve(sessionID: request.sessionID, answers: structured)
            return .accepted
        }

        guard !typed.isEmpty else { return .failed("Empty instruction") }

        if intent == .steer {
            guard session?.agent == .codex else {
                return .failed("\(session?.agent.displayName ?? "This agent") sessions can't take instructions from here")
            }
            guard session?.status != .done else {
                return .failed("This turn has already ended")
            }
            guard await steer(request.sessionID, typed) else {
                return .failed("The agent refused the instruction")
            }
            await store.endQuestion(sessionID: request.sessionID, at: Date())
            return .accepted
        }

        if intent == .continue {
            guard session?.agent == .codex else {
                return .failed("\(session?.agent.displayName ?? "This agent") sessions can't continue from here")
            }
            guard session?.status == .done else {
                return .failed("This session is still running")
            }
            guard await startTurn(request.sessionID, typed) else {
                return .failed("Couldn't start the next turn")
            }
            return .accepted
        }

        // No explicit intent and not a Codex thread: the old Claude "type into
        // the pane" path. Never used when a question was pending — that already
        // took the answer branch and failed if nothing was waiting.
        guard request.intent == nil else {
            return .failed("This agent can't take that action from here")
        }
        guard let ref = await store.terminalRef(for: request.sessionID) else {
            return .failed("Nothing was waiting, and there is no tmux pane to type into.")
        }
        inject(ref, typed)
        await store.endQuestion(sessionID: request.sessionID, at: Date())
        return .accepted
    }

    /// When an older client omits intent: a live or leftover question is
    /// Answer (and will fail if the wait is gone); Codex follows status;
    /// everything else falls through to tmux.
    private func inferredIntent(session: AgentSession?, waiting: Bool, pending: PendingQuestion?) -> SessionActionIntent? {
        if waiting || pending != nil { return .answer }
        guard session?.agent == .codex else { return nil }
        return session?.status == .done ? .continue : .steer
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
