import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

struct GrokBotObservationTests {
    let now = Date(timeIntervalSince1970: 1_000)
    func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func agent(_ id: String, running: Bool = false, seq: Int = 0, nonce: String? = nil,
               message: String? = nil, waiting: Bool = false, outcome: String = "success") -> [String: Any] {
        var row: [String: Any] = ["id": id, "name": "Test \(id)", "isRunning": running,
                                 "snapshotEpoch": "epoch-1", "snapshotSeq": seq,
                                 "awaitingUserResponse": waiting ? ["kind": "question"] : NSNull()]
        if let nonce { row["lastTurnSettlement"] = ["clientNonce": nonce, "outcome": outcome, "settledAtMs": now.timeIntervalSince1970 * 1000] }
        if let message {
            row["lastMessageId"] = message
            row["pushMessageContent"] = ["message": ["id": message, "kind": "send-message", "message": ["type": "text"]]]
        }
        return row
    }
    func baseline(_ rows: [[String: Any]], observer: inout GrokBotObservation,
                  existing: Set<String> = []) throws -> [HookEvent] {
        let value = try JSONSerialization.data(withJSONObject: rows)
        return observer.baseline(try JSONDecoder().decode([GrokBotObservation.Agent].self, from: value), now: now,
                                 existingSessionIDs: existing)
    }
    func state(_ row: [String: Any], observer: inout GrokBotObservation) throws -> [HookEvent] {
        try observer.receive(data(["channel": "agent-upserted", "payload": ["activeAgentId": "wrong-bot", "agent": row]]), now: now)
    }
    func entry(_ row: [String: Any], bot: String, observer: inout GrokBotObservation) throws -> [HookEvent] {
        try observer.receive(data(["channel": "transcript", "payload": ["type": "updated", "agentId": bot, "entry": row]]), now: now)
    }
    func user(_ nonce: String, request: String) -> [String: Any] {
        ["id": "user-\(nonce)", "kind": "message", "role": "user", "clientNonce": nonce,
         "requestId": request, "isStreaming": false, "timestampMs": now.timeIntervalSince1970 * 1000]
    }
    func final(_ request: String, text: String, extra: [String: Any] = [:]) -> [String: Any] {
        ["id": "colliding-message", "kind": "send-message", "requestId": request,
         "message": ["type": "text", "content": text]].merging(extra) { _, value in value }
    }

    @Test func twoBotsWithCollidingMessageIDsProduceDifferentFrozenResults() throws {
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        var reducer = SessionReducer()
        var results = CompletionResults()
        func apply(_ events: [HookEvent]) {
            for event in events {
                reducer.apply(event)
                results.observe(event, session: reducer.sessions[event.sessionID], sourceID: "mac", now: now)
            }
        }
        apply(try baseline([agent("a"), agent("b")], observer: &observer))
        apply(try entry(user("turn-a", request: "request-a"), bot: "a", observer: &observer))
        apply(try entry(user("turn-b", request: "request-b"), bot: "b", observer: &observer))
        apply(try state(agent("a", running: true, seq: 1), observer: &observer))
        apply(try state(agent("b", running: true, seq: 1), observer: &observer))
        apply(try entry(final("request-b", text: "Result B"), bot: "b", observer: &observer))
        apply(try entry(final("request-a", text: "Result A"), bot: "a", observer: &observer))
        apply(try state(agent("b", seq: 2, nonce: "turn-b", message: "colliding-message"), observer: &observer))
        apply(try state(agent("a", seq: 2, nonce: "turn-a", message: "colliding-message"), observer: &observer))
        for (bot, text) in [("a", "Result A"), ("b", "Result B")] {
            let id = observer.sessionID(bot)
            #expect(reducer.sessions[id]?.hasUnreadCompletion == true)
            guard case .ready(let frozen) = results.candidates[id]?.outcome else { Issue.record("No frozen result for \(bot)"); continue }
            #expect(frozen.finalText == text)
            #expect(frozen.completionID == "grokBot:account:\(bot):turn-\(bot)")
        }
        #expect(try state(agent("a", seq: 2, nonce: "turn-a", message: "colliding-message"), observer: &observer).isEmpty)
    }

    @Test func reconnectBaselineCannotEndOrAutoFollowExistingWork() async throws {
        let store = SessionStore(sourceID: "isolated")
        let id = "grokBot:account:a"
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: id, agent: .grokBot,
                                    observationSource: .gateway, timestamp: now))
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        let events = try baseline([agent("a", nonce: "historical")], observer: &observer, existing: [id])
        #expect(events.isEmpty)
        let snapshot = await store.snapshot(now: now)
        #expect(snapshot.sessions.first?.status == .working)
        #expect(snapshot.sessions.first?.effectiveAttention == .normal)
        #expect(snapshot.sessions.first?.hasUnreadCompletion == false)
        #expect(try state(agent("a", seq: 1, nonce: "historical"), observer: &observer).isEmpty)
    }

    @Test func lateOldResultCannotClearANewWaitOrWorkingState() throws {
        for waiting in [true, false] {
            var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
            _ = try baseline([agent("a")], observer: &observer)
            _ = try entry(user("A", request: "request-A"), bot: "a", observer: &observer)
            _ = try state(agent("a", running: true, seq: 1), observer: &observer)
            #expect(try state(agent("a", seq: 2, nonce: "A", message: "colliding-message"), observer: &observer).last?.kind == .stop)
            let next = try state(agent("a", running: !waiting, seq: 3, nonce: "A", waiting: waiting), observer: &observer)
            #expect(next.last?.kind == (waiting ? .notification : .userPromptSubmit))
            #expect(try entry(final("request-A", text: "Late old A"), bot: "a", observer: &observer).isEmpty)
        }
    }

    @Test func interAgentStreamingAndWrongRequestCannotBecomeFinalText() throws {
        for extra in [["toAgent": ["id": "other"]], ["isStreaming": true], ["requestId": "unrelated"]] as [[String: Any]] {
            var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
            _ = try baseline([agent("a")], observer: &observer)
            _ = try entry(user("A", request: "request-A"), bot: "a", observer: &observer)
            _ = try state(agent("a", running: true, seq: 1), observer: &observer)
            _ = try entry(final("request-A", text: "Must not summarize", extra: extra), bot: "a", observer: &observer)
            let completion = try state(agent("a", seq: 2, nonce: "A", message: "colliding-message"), observer: &observer)
            #expect(completion.last?.kind == .stop)
            #expect(completion.last?.completionText == nil)
        }
    }

    @Test func waitingAndUnknownOutcomeNeverClaimSuccess() throws {
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        _ = try baseline([agent("a")], observer: &observer)
        _ = try entry(user("A", request: "request-A"), bot: "a", observer: &observer)
        _ = try state(agent("a", running: true, seq: 1), observer: &observer)
        let wait = try state(agent("a", seq: 2, nonce: "A", waiting: true), observer: &observer)
        #expect(wait.last?.kind == .notification)
        #expect(try state(agent("a", seq: 3, nonce: "A", outcome: "not-a-known-outcome"), observer: &observer).isEmpty)
        #expect(observer.health == .unknownVersion)
    }
    @Test func reconnectRestoresExplicitWaitWithoutACompletionOrInteraction() async throws {
        let store = SessionStore(sourceID: "isolated")
        let id = "grokBot:account:a"
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: id, agent: .grokBot,
                                    observationSource: .gateway, timestamp: now))
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        for event in try baseline([agent("a", waiting: true)], observer: &observer, existing: [id]) {
            await store.ingest(event)
        }
        let session = await store.snapshot(now: now).sessions.first
        #expect(session?.status == .needsResponse)
        #expect(session?.effectiveAttention == .normal)
        #expect(session?.hasUnreadCompletion == false)
    }

    @Test func delayedSettlementStillCompletesButResultExpires() throws {
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        var reducer = SessionReducer()
        var results = CompletionResults()
        func apply(_ events: [HookEvent], at observed: Date) {
            for event in events {
                reducer.apply(event)
                results.observe(event, session: reducer.sessions[event.sessionID], sourceID: "mac", now: observed)
            }
        }
        apply(try baseline([agent("a")], observer: &observer), at: now)
        apply(try entry(user("A", request: "request-A"), bot: "a", observer: &observer), at: now)
        apply(try state(agent("a", running: true, seq: 1), observer: &observer), at: now)
        apply(try entry(final("request-A", text: "Correct but late"), bot: "a", observer: &observer), at: now)
        let delayed = now.addingTimeInterval(3)
        let ending = try observer.receive(data(["channel": "agent-upserted", "payload": ["agent": agent("a", seq: 2, nonce: "A", message: "colliding-message")]]), now: delayed)
        apply(ending, at: delayed)
        let id = observer.sessionID("a")
        #expect(reducer.sessions[id]?.status == .done)
        #expect(reducer.sessions[id]?.hasUnreadCompletion == true)
        #expect(results.candidates[id]?.outcome == .expired)
    }

    @Test func nativeWidgetOutranksSuccessfulSettlementAndAnswerCannotReuseIt() throws {
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        var reducer = SessionReducer()
        func apply(_ events: [HookEvent]) { for e in events { reducer.apply(e) } }
        apply(try baseline([agent("a")], observer: &observer))
        apply(try entry(user("A", request: "request-A"), bot: "a", observer: &observer))
        apply(try state(agent("a", running: true, seq: 1), observer: &observer))
        let widget: [String: Any] = ["id": "question", "kind": "send-message", "requestId": "request-A",
            "timestampMs": now.timeIntervalSince1970 * 1000,
            "message": ["type": "widget", "widget": ["prompt": "Continue?", "options": [["value": "yes", "label": "Yes"]]]]]
        var terminalWidget = agent("a", seq: 2, nonce: "A", message: "question")
        terminalWidget["pushMessageContent"] = ["message": widget]
        // The roster may arrive before the transcript event.
        apply(try state(terminalWidget, observer: &observer))
        apply(try entry(widget, bot: "a", observer: &observer))
        let id = observer.sessionID("a")
        #expect(reducer.sessions[id]?.status == .needsResponse)
        #expect(reducer.sessions[id]?.hasUnreadCompletion == false)
        #expect(reducer.sessions[id]?.pendingQuestion?.isAnswerable == false)
        apply(try entry(widget.merging(["respondedValue": "yes"]) { _, value in value }, bot: "a", observer: &observer))
        apply(try state(agent("a", running: true, seq: 3, nonce: "A", message: "question"), observer: &observer))
        apply(try state(agent("a", seq: 4, nonce: "A", message: "question"), observer: &observer))
        #expect(reducer.sessions[id]?.status == .working)
        #expect(reducer.sessions[id]?.hasUnreadCompletion == false)
        #expect(observer.health == .eventsMissing)
    }

    @Test func baselineOnlyCurrentUnansweredWidgetBecomesAReadOnlyWait() throws {
        let widget = try JSONDecoder().decode(GrokBotObservation.Entry.self, from: data([
            "id": "question", "kind": "send-message", "requestId": "old-request", "timestampMs": 999_000,
            "message": ["type": "widget", "widget": ["prompt": "Continue?"]]]))
        for current in [true, false] {
            var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
            let row = try JSONDecoder().decode(GrokBotObservation.Agent.self, from: data(agent("a", message: current ? "question" : "newer-final")))
            let events = observer.baseline([row], now: now, tails: ["a": [widget]])
            #expect(events.contains(where: { $0.kind == .notification }) == current)
            #expect(!events.contains(where: { $0.kind == .stop }))
            #expect(events.last?.waitKind == (current ? .question : nil))
        }
    }

    @Test func successWithMissingLastMessageCannotHideANativeQuestion() throws {
        var observer = GrokBotObservation(accountScope: "account", connectedAt: now)
        _ = try baseline([agent("a")], observer: &observer)
        _ = try entry(user("A", request: "request-A"), bot: "a", observer: &observer)
        _ = try state(agent("a", running: true, seq: 1), observer: &observer)
        #expect(try state(agent("a", seq: 2, nonce: "A"), observer: &observer).isEmpty)
        #expect(observer.health == .unknownVersion)
    }

}
