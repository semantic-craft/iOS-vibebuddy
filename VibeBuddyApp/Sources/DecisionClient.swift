import Foundation
import VibeBuddyKit

/// POSTs an approve/deny decision back to the Mac. Best-effort: failures are
/// swallowed (the daemon will time out and fall back).
protocol DecisionClient: Sendable {
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async
    /// Returns what the Mac reported, or `nil` if it couldn't be reached.
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome?
}

struct HTTPDecisionClient: DecisionClient {
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/decision") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["approvalId": approvalId, "decision": decision.rawValue]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
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
