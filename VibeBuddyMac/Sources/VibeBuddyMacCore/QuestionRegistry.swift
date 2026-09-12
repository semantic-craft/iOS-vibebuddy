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
        let questionID: String?
        let continuation: CheckedContinuation<QuestionAnswers?, Never>
    }

    private var waiters: [String: Waiter] = [:]
    private var early: [String: QuestionAnswers] = [:]

    public init() {}

    /// Whether an agent is waiting on this session right now, so a caller can
    /// choose between resolving a wait and typing into a terminal.
    public func isWaiting(sessionID: String) -> Bool { waiters[sessionID] != nil }

    public func wait(sessionID: String, questionID: String? = nil, timeout: Duration) async -> QuestionAnswers? {
        if let answers = early.removeValue(forKey: sessionID) { return answers }
        let token = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<QuestionAnswers?, Never>) in
            // A newer question on the same session supersedes the old wait.
            waiters[sessionID]?.continuation.resume(returning: nil)
            waiters[sessionID] = Waiter(token: token, questionID: questionID, continuation: cont)
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

    /// Exact phone answers cannot spill into a later wait or a terminal.
    public func resolveExact(sessionID: String, questionID: String, answers: QuestionAnswers) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let waiter = waiters[sessionID], waiter.questionID == questionID else { return false }
        waiters.removeValue(forKey: sessionID)
        waiter.continuation.resume(returning: answers)
        return true
    }

    /// The agent resolved or dropped the question elsewhere: stop waiting.
    public func cancel(sessionID: String) {
        waiters.removeValue(forKey: sessionID)?.continuation.resume(returning: nil)
    }

    public func cancelExact(sessionID: String, questionID: String) {
        guard waiters[sessionID]?.questionID == questionID else { return }
        cancel(sessionID: sessionID)
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

    private var inFlight: Set<String> = []
    public func claim(_ id: String) -> SessionActionDelivery? {
        if let previous = seen[id] { return previous }
        if !inFlight.insert(id).inserted { return .unknown }
        return nil
    }

    public func remember(_ id: String, _ result: SessionActionDelivery) {
        inFlight.remove(id)
        if seen[id] == nil { order.append(id) }
        seen[id] = result
        while order.count > limit {
            seen.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Daemon-side result of one session action. The phone maps this onto
/// its local receipt state (adding not-sent / unknown around the transport).
public enum SessionActionDelivery: Equatable, Sendable {
    case accepted
    case unknown
    /// The action no longer applies to this session — the turn it named has
    /// moved on, or this agent cannot take it. Nothing was attempted and
    /// nothing will be; the client should look at the current state, not
    /// retry. Only `stop` distinguishes this from `failed` so far.
    case refused(String)
    case failed(String)
}

/// Where a phone or Mac action goes: to the waiting agent through its own
/// contract, else Codex `turn/steer` / `turn/start` / `turn/interrupt` by
/// intent, else a tmux pane for an old no-intent Claude reply. Steer never
/// becomes start, and a stop never becomes anything else.
public struct AnswerDispatch: Sendable {
    public let store: SessionStore
    public let questions: QuestionRegistry
    public let inject: @Sendable (TerminalRef, String) -> Void
    /// Codex `turn/steer` only. False when the daemon refused or there is no
    /// connection — the caller must not start a turn.
    public let steer: @Sendable (String, String) async -> Bool
    /// Codex `turn/start` (resume first when the thread is cold).
    public let startTurn: @Sendable (String, String) async -> Bool
    /// Codex `turn/interrupt`. Says whether it was sent, definitely not sent
    /// (with the reason), or sent without an answer — never retried here, and
    /// never followed by another method.
    public let interrupt: @Sendable (String) async -> CodexAppServerMonitor.InterruptOutcome
    public let requests: ActionRequestLog

    public init(store: SessionStore, questions: QuestionRegistry,
                inject: @escaping @Sendable (TerminalRef, String) -> Void,
                steer: @escaping @Sendable (String, String) async -> Bool = { _, _ in false },
                startTurn: @escaping @Sendable (String, String) async -> Bool = { _, _ in false },
                interrupt: @escaping @Sendable (String) async -> CodexAppServerMonitor.InterruptOutcome
                    = { _ in .notSent(String(localized: "This Mac cannot stop Codex tasks.")) },
                requests: ActionRequestLog = ActionRequestLog()) {
        self.store = store
        self.questions = questions
        self.inject = inject
        self.steer = steer
        self.startTurn = startTurn
        self.interrupt = interrupt
        self.requests = requests
    }

    /// Older callers: infer intent from the live session and return whether
    /// anything was delivered.
    @discardableResult
    public func deliver(sessionID: String, text: String?, answers: QuestionAnswers?, expectedQuestionID: String? = nil, expectedStatusSince: Double? = nil) async -> Bool {
        let result = await deliver(SessionActionRequest(sessionID: sessionID, questionID: expectedQuestionID, expectedStatusSince: expectedStatusSince, text: text, answers: answers))
        if case .accepted = result { return true }
        return false
    }

    public func deliver(_ request: SessionActionRequest) async -> SessionActionDelivery {
        if let prior = await requests.claim(request.requestID) { return prior }
        let result = await execute(request)
        await requests.remember(request.requestID, result)
        return result
    }

    private func execute(_ request: SessionActionRequest) async -> SessionActionDelivery {
        guard !Task.isCancelled else { return .failed("Cancelled before sending") }
        let session = await store.snapshot(now: Date()).sessions.first { $0.id == request.sessionID }
        let pending = session?.pendingQuestion
        let waiting = await questions.isWaiting(sessionID: request.sessionID)
        guard !Task.isCancelled else { return .failed("Cancelled before sending") }
        let structured = Self.normalize(answers: request.answers, text: request.text, for: pending)
        let typed = request.text ?? Self.flatten(structured)
        let intent = request.intent ?? inferredIntent(session: session, waiting: waiting, pending: pending)

        // A stop carries no text and is never inferred, so it skips every
        // answer-shaped check and is decided against the live session alone.
        if intent == .stop { return await stop(request, session: session) }

        guard session?.pendingApproval == nil, pending?.isAnswerable != false,
              pending?.expiresAt.map({ $0 > Date() }) != false else { return .failed("This wait cannot be answered here") }
        if let expected = request.expectedStatusSince {
            guard let session, abs(session.statusSince.timeIntervalSince1970 - expected) < 0.001 else {
                return .failed("This task has changed")
            }
        }
        if intent == .answer {
            guard waiting, let pending, !structured.isEmpty,
                  request.questionID == nil || request.questionID == pending.id else {
                return .failed("This question is no longer waiting")
            }
            return await questions.resolveExact(sessionID: request.sessionID, questionID: pending.id, answers: structured)
                ? .accepted : .failed("This question is no longer waiting")
        }
        guard pending == nil, session?.status != .needsResponse else { return .failed("Answer the current wait first") }

        guard !typed.isEmpty else { return .failed("Empty instruction") }

        if intent == .steer {
            guard session?.agent == .codex else {
                return .failed("\(session?.agent.displayName ?? "This agent") sessions can't take instructions from here")
            }
            guard session?.status != .done else {
                return .failed("This turn has already ended")
            }
            guard await steer(request.sessionID, typed) else {
                return .unknown
            }
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
                return .unknown
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
        guard E2ERunConfiguration.current == nil else {
            return .failed("Terminal injection is disabled during isolated acceptance")
        }
        guard !Task.isCancelled else { return .failed("Cancelled before sending") }
        inject(ref, typed)
        return .accepted
    }

    /// Interrupt the turn the client was looking at, or say why not.
    ///
    /// The identity is the session's `statusSince` — the moment it entered
    /// `working`. It is required, not optional: a stop with no turn to name
    /// could only be aimed at "whatever is running now", which is how a stale
    /// wrist tap ends a turn the user never saw.
    ///
    /// Three different answers, because they mean three different things to
    /// the person who tapped: `refused` — this stop no longer applies, look at
    /// the task; `failed` — nothing was sent, and the reason says why;
    /// `unknown` — it went out and the connection died, so check on the Mac.
    private func stop(_ request: SessionActionRequest, session: AgentSession?) async -> SessionActionDelivery {
        guard let session else { return .refused("This task is no longer on this Mac") }
        let support = SessionActionSupport.resolveStop(for: session)
        guard support.isAvailable else {
            return .refused(support.unsupportedReason ?? "This task can't be stopped from here")
        }
        guard let expected = request.expectedStatusSince else {
            return .refused("A stop must name the turn it is for")
        }
        guard abs(session.statusSince.timeIntervalSince1970 - expected) < 0.001 else {
            return .refused("This task has changed")
        }
        switch await interrupt(request.sessionID) {
        case .sent: return .accepted
        case .notSent(let why): return .failed(why)
        case .unconfirmed: return .unknown
        }
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
