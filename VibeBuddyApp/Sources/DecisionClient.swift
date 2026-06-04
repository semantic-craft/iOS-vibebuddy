import Foundation
import VibeBuddyKit

/// POSTs an approve/deny decision back to the Mac. Best-effort: failures are
/// swallowed (the daemon will time out and fall back).
protocol DecisionClient: Sendable {
    func decide(_ pairing: PairingPayload, approvalId: String, approve: Bool) async
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async
    func jump(_ pairing: PairingPayload, sessionId: String) async
}

struct HTTPDecisionClient: DecisionClient {
    func decide(_ pairing: PairingPayload, approvalId: String, approve: Bool) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/decision") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["approvalId": approvalId, "decision": approve ? "allow" : "deny"]
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

    func jump(_ pairing: PairingPayload, sessionId: String) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/jump") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        _ = try? await URLSession.shared.data(for: req)
    }
}
