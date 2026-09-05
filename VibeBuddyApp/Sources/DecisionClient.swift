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
    /// Follow or unfollow a session so the Mac keeps reminding about its
    /// completion until it is read.
    func follow(_ pairing: PairingPayload, sessionId: String, followed: Bool) async
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

    func follow(_ pairing: PairingPayload, sessionId: String, followed: Bool) async {
        guard let url = URL(string: "http://\(pairing.host):\(pairing.port)/follow") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId, "followed": followed])
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
