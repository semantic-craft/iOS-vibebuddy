import Foundation
import VibeBuddyKit

/// POSTs an approve/deny decision back to the Mac.
protocol DecisionClient: Sendable {
    func history(_ pairing: PairingPayload, sourceID: String, key: String, cursor: String?) async throws -> HistoryPage
    func contentStyle(_ pairing: PairingPayload) async throws -> ContentStyleState
    func updateContentStyle(_ pairing: PairingPayload, update: ContentStyleUpdate) async throws -> ContentStyleState
    func presentation(_ pairing: PairingPayload, request: ContentPresentationRequest) async throws -> ContentPresentation
    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot?
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult
    /// The same decision under an idempotency key. A held decision
    /// (`PendingActionStore`) is retried under one `requestID`, and the Mac's
    /// `ActionRequestLog` answers a repeat as it answered the first time
    /// instead of resolving — or refusing — a second time (ADR-0032).
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                       requestID: String) async -> PhoneActionResult
    /// Answer the session's current question. `requestID` identifies the *tap*:
    /// the daemon's `ActionRequestLog` de-duplicates on it, so one gesture
    /// replayed cannot answer twice. A caller with no gesture to name (the
    /// phone's own composer) leaves it to a fresh id.
    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?, requestID: String) async -> PhoneActionResult
    /// End the session's running turn. Carries no text: the turn is named by
    /// the `statusSince` the caller just re-read from an authenticated
    /// snapshot, and the daemon refuses the stop rather than moving it onto a
    /// later turn.
    func phoneStop(_ pairing: PairingPayload, session: AgentSession, requestID: String) async -> StopDelivery
    /// Watch's existing simple receipt contract. Phone cards use the richer
    /// phone result so uncertain delivery cannot be reported as success.
    @discardableResult
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool
    /// Same POST as `decide`, but distinguishes 404/409 (wait already gone).
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult
    /// The banner's decision under an idempotency key, and `.unreachable`
    /// when nothing answered — the one result a decision may be held on.
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                      requestID: String) async -> WaitActionResult
    /// Same POST as `answer`, but distinguishes 404/409 (wait already gone).
    @discardableResult
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer: String) async -> WaitActionResult
    /// Returns what the Mac reported, or `nil` if it couldn't be reached.
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome?
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome
    /// Mark all on the wrist: move the Mac's recap horizon forward. Rounds are
    /// still read one by one with `acknowledge`; this only narrows the recap.
    func advanceRecapHorizon(_ pairing: PairingPayload, request: RecapReadRequest) async -> RecapReadOutcome
    /// Start a new task; nil when the Mac could not be reached.
    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome?
    /// Set how much a session may interrupt you, or `nil` to return it to the
    /// daemon's automatic level. The Mac owns the value.
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async
    /// Bounded recent dialogue. Nil when the Mac could not be reached.
    func workspaceChanges(_ pairing: PairingPayload, sessionId: String, scope: ChangesScope, baseline: String?, file: String?) async -> WorkspaceChanges?
    func completionBody(_ pairing: PairingPayload, sessionId: String, completionId: String) async -> CompletionBody?
    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput?
}

/// Defaults so a test double implements only the routes its test exercises.
///
/// **Changing a requirement's signature here is not a compile error at the call
/// sites that matter.** A conformer still carrying the old signature keeps
/// compiling — its method simply stops satisfying the requirement, and every
/// protocol-typed caller silently gets the default below instead. Because these
/// defaults are shaped like *outcomes* (`.failed`, `nil`) rather than crashes,
/// the result reads as a Mac that refused rather than as a wiring mistake. That
/// is how the `requestID:` parameter landed on `phoneAnswer` with a stale
/// double in `DashboardStoreTests` quietly answering `.failed` for three tests.
///
/// So: after changing any signature in this protocol, grep for the method name
/// across `VibeBuddyApp` and update every conformer by hand. The compiler will
/// not do it for you.
enum ContentRequestFailure: Error { case unavailable, conflict, invalid }

extension DecisionClient {
    func history(_ pairing: PairingPayload, sourceID: String, key: String, cursor: String?) async throws -> HistoryPage { throw HistoryFailure("source_unavailable") }
    func contentStyle(_ pairing: PairingPayload) async throws -> ContentStyleState { throw ContentRequestFailure.unavailable }
    func updateContentStyle(_ pairing: PairingPayload, update: ContentStyleUpdate) async throws -> ContentStyleState { throw ContentRequestFailure.unavailable }
    func presentation(_ pairing: PairingPayload, request: ContentPresentationRequest) async throws -> ContentPresentation { throw ContentRequestFailure.unavailable }
    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? { nil }
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult { .failed }
    /// A double that knows nothing of keys answers the keyless form.
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                       requestID: String) async -> PhoneActionResult {
        await phoneDecision(pairing, approvalId: approvalId, decision: decision)
    }
    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?, requestID: String) async -> PhoneActionResult { .failed }

    /// The phone's own composer: one send, one fresh request id.
    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?) async -> PhoneActionResult {
        await phoneAnswer(pairing, session: session, text: text, answers: answers,
                          requestID: UUID().uuidString)
    }
    func phoneStop(_ pairing: PairingPayload, session: AgentSession, requestID: String) async -> StopDelivery { .failed }
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool { false }
    func advanceRecapHorizon(_ pairing: PairingPayload, request: RecapReadRequest) async -> RecapReadOutcome { .failed }
    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome? { nil }
    func workspaceChanges(_ pairing: PairingPayload, sessionId: String, scope: ChangesScope, baseline: String?, file: String?) async -> WorkspaceChanges? { nil }
    func completionBody(_ pairing: PairingPayload, sessionId: String, completionId: String) async -> CompletionBody? { nil }
    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput? { nil }
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult {
        await decide(pairing, approvalId: approvalId, decision: decision) ? .accepted : .failed
    }
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                      requestID: String) async -> WaitActionResult {
        await decideResult(pairing, approvalId: approvalId, decision: decision)
    }
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer text: String) async -> WaitActionResult {
        return .failed
    }
}

struct HTTPDecisionClient: DecisionClient {
    func history(_ pairing: PairingPayload, sourceID: String, key: String, cursor: String?) async throws -> HistoryPage {
        guard let url = pairing.companionURL(path: "history"), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw HistoryFailure("source_unavailable") }
        parts.queryItems = [URLQueryItem(name: "sourceID", value: sourceID), URLQueryItem(name: "key", value: key), URLQueryItem(name: "limit", value: "30")]
        if let cursor { parts.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        guard let endpoint = parts.url else { throw HistoryFailure("invalid_request") }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HistoryFailure("source_unavailable") }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw HistoryFailure("unauthorized") }
            throw (try? JSONDecoder().decode(HistoryFailure.self, from: data)) ?? HistoryFailure("source_unavailable")
        }
        guard data.count <= 1_048_576 else { throw HistoryFailure("message_exceeds_budget") }
        return try JSONDecoder().decode(HistoryPage.self, from: data)
    }

    func contentStyle(_ pairing: PairingPayload) async throws -> ContentStyleState {
        try await contentRequest(pairing, path: "content-style", method: "GET", body: nil)
    }

    func updateContentStyle(_ pairing: PairingPayload, update: ContentStyleUpdate) async throws -> ContentStyleState {
        try await contentRequest(pairing, path: "content-style", method: "PUT", body: JSONEncoder().encode(update))
    }

    func presentation(_ pairing: PairingPayload, request: ContentPresentationRequest) async throws -> ContentPresentation {
        try await contentRequest(pairing, path: "presentation", method: "POST", body: JSONEncoder().encode(request))
    }

    private func contentRequest<T: Decodable>(_ pairing: PairingPayload, path: String, method: String, body: Data?) async throws -> T {
        guard let url = pairing.companionURL(path: path) else { throw ContentRequestFailure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = path == "presentation" ? 45 : 10
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return try JSONDecoder().decode(T.self, from: data)
        case 409: throw ContentRequestFailure.conflict
        case 400: throw ContentRequestFailure.invalid
        default: throw ContentRequestFailure.unavailable
        }
    }

    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? {
        guard let url = pairing.companionURL(path: "snapshot") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult {
        await phoneDecision(pairing, approvalId: approvalId, decision: decision, requestID: UUID().uuidString)
    }

    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                       requestID: String) async -> PhoneActionResult {
        await postAction(pairing, path: "decision",
                         body: ["approvalId": approvalId, "decision": decision.rawValue, "requestId": requestID])
    }

    /// The Mac's unauthenticated `/health`, with a short clock: whether this
    /// phone has a road to the Mac right now, and if not, which link is out.
    func probe(_ pairing: PairingPayload) async -> ReachabilityProbe {
        guard let url = pairing.companionURL(path: "health") else { return .unreachable(.invalidAddress) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 200 { return .reachable }
            return .unreachable(.macUnreachable(host: pairing.host))
        } catch {
            return .unreachable(ConnectionDiagnosis.diagnose(
                endpoint: pairing.endpoint, kind: .unreachable, phoneHasTailnet: PhoneNetwork.hasTailnetAddress()))
        }
    }

    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?,
                     answers: QuestionAnswers?, requestID: String) async -> PhoneActionResult {
        var body: [String: Any] = ["sessionId": session.id,
                                   "expectedQuestionId": session.pendingQuestion?.id ?? "",
                                   "intent": SessionActionSupport.resolve(for: session).intent.rawValue,
                                   "requestId": requestID,
                                   "expectedStatusSince": session.statusSince.timeIntervalSince1970]
        if let text { body["answer"] = text }
        if let answers { body["answers"] = answers }
        return await postAction(pairing, path: "answer", body: body)
    }

    func phoneStop(_ pairing: PairingPayload, session: AgentSession, requestID: String) async -> StopDelivery {
        // The same `/answer` route every session action uses; `intent` is what
        // makes it a stop, and a stop is the one intent that may carry no text.
        let body: [String: Any] = ["sessionId": session.id,
                                   "intent": SessionActionIntent.stop.rawValue,
                                   "requestId": requestID,
                                   "expectedStatusSince": session.statusSince.timeIntervalSince1970]
        guard let url = pairing.companionURL(path: "answer"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = data
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (payload, _) = try await URLSession.shared.data(for: request)
            let fields = (try? JSONDecoder().decode([String: String].self, from: payload)) ?? [:]
            return StopDelivery(status: fields["status"])
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost: return .failed
            default: return .unconfirmed
            }
        } catch { return .unconfirmed }
    }

    private func postAction(_ pairing: PairingPayload, path: String, body: [String: Any]) async -> PhoneActionResult {
        guard !Task.isCancelled else { return .failed }
        guard let url = pairing.companionURL(path: path),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = data
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return PhoneActionResult(statusCode: (response as? HTTPURLResponse)?.statusCode)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost: return .failed
            default: return .unconfirmed // A timeout/drop may occur after the Mac accepted it.
            }
        } catch { return .unconfirmed }
    }

    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool {
        guard let url = pairing.companionURL(path: "acknowledge-wait") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome {
        guard let url = pairing.companionURL(path: "acknowledge") else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let result = try? JSONDecoder().decode(CompletionReadResponse.self, from: data)
        else { return .failed }
        return result.outcome
    }

    func advanceRecapHorizon(_ pairing: PairingPayload, request: RecapReadRequest) async -> RecapReadOutcome {
        guard let url = pairing.companionURL(path: "recap-read") else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200..<300: return .accepted
        case 409: return .sourceMismatch
        default: return .failed
        }
    }

    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {
        guard let url = pairing.companionURL(path: "attention") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["sessionId": sessionId, "attention": level?.rawValue ?? NSNull()]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    @discardableResult
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool {
        await decideResult(pairing, approvalId: approvalId, decision: decision) == .accepted
    }

    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult {
        await decideResult(pairing, approvalId: approvalId, decision: decision, requestID: UUID().uuidString)
    }

    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision,
                      requestID: String) async -> WaitActionResult {
        guard let url = pairing.companionURL(path: "decision") else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["approvalId": approvalId, "decision": decision.rawValue, "requestId": requestID]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // No answer at all — refused route, no route, timeout — is the one
        // ending a decision may be held on. With the key on the wire, a
        // timeout that did land is answered as a duplicate later, not applied.
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return .unreachable }
        return WaitActionResult(statusCode: (response as? HTTPURLResponse)?.statusCode)
    }

    func answerResult(_ pairing: PairingPayload, sessionId: String, answer: String) async -> WaitActionResult {
        guard let url = pairing.companionURL(path: "answer") else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "answer": answer])
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return .failed }
        let status = (response as? HTTPURLResponse)?.statusCode
        return status == 202 ? .alreadyResolved : WaitActionResult(statusCode: status)
    }

    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome? {
        guard let url = pairing.companionURL(path: "dispatch") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["agent": request.agent.rawValue, "cwd": request.cwd, "prompt": request.prompt]
        if let name = request.name { body["name"] = name }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return nil }
        let fields = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        switch http.statusCode {
        case 200: return fields["sessionId"].map { .started(sessionID: $0) }
        case 400: return .rejected(fields["error"] ?? "Refused")
        case 501: return .unsupported(fields["error"] ?? "Not supported")
        case 503: return .unavailable(fields["error"] ?? "Unavailable")
        default: return nil
        }
    }

    func workspaceChanges(_ pairing: PairingPayload, sessionId: String, scope: ChangesScope, baseline: String?, file: String?) async -> WorkspaceChanges? {
        var items = [URLQueryItem(name: "sessionId", value: sessionId), URLQueryItem(name: "scope", value: scope.rawValue)]
        if let baseline { items.append(URLQueryItem(name: "baseline", value: baseline)) }
        if let file { items.append(URLQueryItem(name: "file", value: file)) }
        guard let url = pairing.companionURL(path: "changes", queryItems: items) else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(WorkspaceChanges.self, from: data)
    }

    func completionBody(_ pairing: PairingPayload, sessionId: String, completionId: String) async -> CompletionBody? {
        guard let base = pairing.companionURL(path: "completion"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "sessionId", value: sessionId), URLQueryItem(name: "completionId", value: completionId)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url); request.timeoutInterval = 10
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(CompletionBody.self, from: data)
    }

    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput? {
        guard let url = pairing.companionURL(path: "recent-output", queryItems: [URLQueryItem(name: "sessionId", value: sessionId)]) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(RecentOutput.self, from: data)
    }

    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? {
        guard let url = pairing.companionURL(path: "jump") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = body["outcome"] else { return nil }   // nil → unreachable / refused
        return JumpOutcome(rawValue: raw)
    }
}
