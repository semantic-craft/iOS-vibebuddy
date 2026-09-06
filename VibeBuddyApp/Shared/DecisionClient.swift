import Foundation
import VibeBuddyKit

/// POSTs an approve/deny decision back to the Mac.
protocol DecisionClient: Sendable {
    /// Returns whether the Mac accepted the decision. The phone's own card can
    /// ignore that (the daemon times out and falls back), but the Watch cannot:
    /// a wrist that says "approved" on a dropped request is lying.
    @discardableResult
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async
    /// Same POST as `decide`, but distinguishes 404/409 (wait already gone).
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult
    /// Same POST as `answer`, but distinguishes 404/409 (wait already gone).
    @discardableResult
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer: String) async -> WaitActionResult
    /// Structured answers keyed by question id (option labels, or a typed
    /// reply), for the agents that take them through their own contract.
    func answer(_ pairing: PairingPayload, sessionId: String, answers: QuestionAnswers) async
    /// Returns what the Mac reported, or `nil` if it couldn't be reached.
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome?
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool
    func acknowledge(_ pairing: PairingPayload, request: CompletionReadRequest) async -> CompletionReadOutcome
    /// Start a new task; nil when the Mac could not be reached.
    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome?
    /// Set how much a session may interrupt you, or `nil` to return it to the
    /// daemon's automatic level. The Mac owns the value.
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async
}

extension DecisionClient {
    func acknowledgeWait(_ pairing: PairingPayload, request: WaitReadRequest) async -> Bool { false }
    func dispatch(_ pairing: PairingPayload, request: DispatchRequest) async -> DispatchOutcome? { nil }
    func decideResult(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> WaitActionResult {
        await decide(pairing, approvalId: approvalId, decision: decision) ? .accepted : .failed
    }
    func answerResult(_ pairing: PairingPayload, sessionId: String, answer text: String) async -> WaitActionResult {
        await answer(pairing, sessionId: sessionId, answer: text)
        return .accepted
    }
}

extension DecisionClient {
    /// Doubles that only speak plain text get the answers flattened.
    func answer(_ pairing: PairingPayload, sessionId: String, answers: QuestionAnswers) async {
        let flat = answers.keys.sorted().compactMap { key -> String? in
            let values = answers[key] ?? []
            return values.isEmpty ? nil : values.joined(separator: ", ")
        }.joined(separator: "\n")
        await answer(pairing, sessionId: sessionId, answer: flat)
    }
}

struct HTTPDecisionClient: DecisionClient {
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

    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {
        _ = await answerResult(pairing, sessionId: sessionId, answer: answer)
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

    func answer(_ pairing: PairingPayload, sessionId: String, answers: QuestionAnswers) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/answer") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "answers": answers])
        _ = try? await URLSession.shared.data(for: req)
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
