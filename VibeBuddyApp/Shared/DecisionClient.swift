import Foundation
import VibeBuddyKit

/// POSTs an approve/deny decision back to the Mac.
protocol DecisionClient: Sendable {
    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot?
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult
    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?, answers: QuestionAnswers?) async -> PhoneActionResult
    /// Watch's existing simple receipt contract. Phone cards use the richer
    /// phone result so uncertain delivery cannot be reported as success.
    @discardableResult
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool
    /// Same POST as `decide`, but distinguishes 404/409 (wait already gone).
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult
    /// Same POST as `answer`, but distinguishes 404/409 (wait already gone).
    @discardableResult
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer: String) async -> WaitActionResult
    /// Returns what the Mac reported, or `nil` if it couldn't be reached.
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome?
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome
    /// Start a new task; nil when the Mac could not be reached.
    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome?
    /// Set how much a session may interrupt you, or `nil` to return it to the
    /// daemon's automatic level. The Mac owns the value.
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async
    /// Bounded recent dialogue. Nil when the Mac could not be reached.
    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput?
}

extension DecisionClient {
    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? { nil }
    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult { .failed }
    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?, answers: QuestionAnswers?) async -> PhoneActionResult { .failed }
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool { false }
    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome? { nil }
    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput? { nil }
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult {
        await decide(pairing, approvalId: approvalId, decision: decision) ? .accepted : .failed
    }
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer text: String) async -> WaitActionResult {
        return .failed
    }
}

struct HTTPDecisionClient: DecisionClient {
    func actionSnapshot(_ pairing: PairingPayload) async -> Snapshot? {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/snapshot") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func phoneDecision(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> PhoneActionResult {
        await postAction(pairing, path: "decision", body: ["approvalId": approvalId, "decision": decision.rawValue])
    }

    func phoneAnswer(_ pairing: PairingPayload, session: AgentSession, text: String?, answers: QuestionAnswers?) async -> PhoneActionResult {
        var body: [String: Any] = ["sessionId": session.id,
                                   "expectedQuestionId": session.pendingQuestion?.id ?? "",
                                   "intent": SessionActionSupport.resolve(for: session).intent.rawValue,
                                   "requestId": UUID().uuidString,
                                   "expectedStatusSince": session.statusSince.timeIntervalSince1970]
        if let text { body["answer"] = text }
        if let answers { body["answers"] = answers }
        return await postAction(pairing, path: "answer", body: body)
    }

    private func postAction(_ pairing: PairingPayload, path: String, body: [String: Any]) async -> PhoneActionResult {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/\(path)"),
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
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/acknowledge-wait") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(request)
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/acknowledge") else { return .failed }
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

    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/attention") else { return }
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
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/decision") else { return .failed }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["approvalId": approvalId, "decision": decision.rawValue]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: req) else { return .failed }
        return WaitActionResult(statusCode: (response as? HTTPURLResponse)?.statusCode)
    }

    func answerResult(_ pairing: PairingPayload, sessionId: String, answer: String) async -> WaitActionResult {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/answer") else { return .failed }
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
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/dispatch") else { return nil }
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

    func recentOutput(_ pairing: PairingPayload, sessionId: String) async -> RecentOutput? {
        var comps = URLComponents(string: "http://\(pairing.host):\(pairing.port)/recent-output")
        comps?.queryItems = [URLQueryItem(name: "sessionId", value: sessionId)]
        guard let url = comps?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return try? JSONDecoder().decode(RecentOutput.self, from: data)
    }

    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/jump") else { return nil }
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
