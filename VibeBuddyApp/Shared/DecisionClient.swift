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
    /// Returns what the Mac reported, or `nil` if it couldn't be reached.
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome?
    func acknowledge(_ pairing: PairingPayload, sessionId: String) async
    /// Set how much a session may interrupt you, or `nil` to return it to the
    /// daemon's automatic level. The Mac owns the value.
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async
}

struct HTTPDecisionClient: DecisionClient {
    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/acknowledge") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        _ = try? await URLSession.shared.data(for: req)
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
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/decision") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["approvalId": approvalId, "decision": decision.rawValue]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        return true
    }

    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/answer") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "answer": answer])
        _ = try? await URLSession.shared.data(for: req)
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
