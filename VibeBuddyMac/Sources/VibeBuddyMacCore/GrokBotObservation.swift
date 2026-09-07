import Foundation
import VibeBuddyKit

/// Only the current turn's bounded result lives here. No transcript is persisted.
struct GrokBotObservation: Sendable {
    struct Settlement: Decodable, Sendable {
        let clientNonce: String
        let outcome: String
        let settledAtMs: Double
    }
    struct Agent: Decodable, Sendable {
        let id: String
        let name: String
        let isRunning: Bool
        let waiting: Bool
        let lastMessageId: String?
        let lastTurnSettlement: Settlement?
        let snapshotEpoch: String?
        let snapshotSeq: Int?
        let widgetID: String?
        let lastMessageType: String?
        struct Push: Decodable { let message: Entry? }
        struct LastEntry: Decodable {
            struct Preview: Decodable { let kind: String? }
            let sessionPreview: Preview?
        }
        enum CodingKeys: String, CodingKey {
            case id, name, isRunning, awaitingUserResponse, lastMessageId, lastTurnSettlement, snapshotEpoch, snapshotSeq, pushMessageContent, lastEntry
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            isRunning = try c.decode(Bool.self, forKey: .isRunning)
            // Unknown waiting subtypes remain read-only and always outrank work.
            let awaiting = try c.contains(.awaitingUserResponse) && !c.decodeNil(forKey: .awaitingUserResponse)
            lastMessageId = try c.decodeIfPresent(String.self, forKey: .lastMessageId)
            lastTurnSettlement = try c.decodeIfPresent(Settlement.self, forKey: .lastTurnSettlement)
            snapshotEpoch = try c.decodeIfPresent(String.self, forKey: .snapshotEpoch)
            snapshotSeq = try c.decodeIfPresent(Int.self, forKey: .snapshotSeq)
            let pushed = try c.decodeIfPresent(Push.self, forKey: .pushMessageContent)?.message
            let preview = try c.decodeIfPresent(LastEntry.self, forKey: .lastEntry)?.sessionPreview?.kind
            lastMessageType = pushed?.id == lastMessageId ? pushed?.message?.type : nil
            widgetID = !isRunning && pushed?.id == lastMessageId && pushed?.unansweredWidget == true && preview != "widget_answered" ? pushed?.id : nil
            waiting = awaiting || widgetID != nil
            guard !id.isEmpty, id.utf8.count <= 256, name.utf8.count <= 1024 else { throw GrokBotGatewayError.invalidResponse }
        }
    }
    struct Entry: Decodable, Sendable {
        struct Message: Decodable, Sendable {
            struct Widget: Decodable, Sendable { let prompt: String? }
            let type: String
            let content: String?
            let widget: Widget?
        }
        let id: String
        let kind: String
        let role: String?
        let clientNonce: String?
        let requestId: String?
        let timestampMs: Double?
        let message: Message?
        let direct: Bool
        let isStreaming: Bool
        let respondedValue: String?
        var unansweredWidget: Bool { kind == "send-message" && message?.type == "widget" && respondedValue == nil }
        enum CodingKeys: String, CodingKey {
            case id, kind, role, clientNonce, requestId, timestampMs, message, fromAgent, toAgent, isStreaming, respondedValue
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            kind = try c.decode(String.self, forKey: .kind)
            role = try c.decodeIfPresent(String.self, forKey: .role)
            clientNonce = try c.decodeIfPresent(String.self, forKey: .clientNonce)
            requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
            timestampMs = try c.decodeIfPresent(Double.self, forKey: .timestampMs)
            message = kind == "send-message" ? try c.decodeIfPresent(Message.self, forKey: .message) : nil
            respondedValue = try c.decodeIfPresent(String.self, forKey: .respondedValue)
            isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
            let from = try c.contains(.fromAgent) && !c.decodeNil(forKey: .fromAgent)
            let to = try c.contains(.toAgent) && !c.decodeNil(forKey: .toAgent)
            direct = !from && !to
        }
    }
    struct Envelope: Decodable, Sendable {
        struct Payload: Decodable, Sendable {
            let agent: Agent?
            let agentId: String?
            let entry: Entry?
            let type: String?
        }
        let channel: String
        let payload: Payload?
    }
    struct Run: Sendable {
        let nonce: String
        var request: String?
        var result: Entry?
    }
    private struct State: Sendable {
        var agent: Agent
        var run: Run?
        var completedNonce: String?
        var completedAt: Date?
        var widgetID: String?
    }
    let accountScope: String
    let connectedAt: Date
    let botNames: Set<String>?
    private(set) var health: ObservationHealth = .healthy
    private var states: [String: State] = [:]

    init(accountScope: String, connectedAt: Date, botNames: Set<String>? = nil) {
        self.accountScope = accountScope
        self.connectedAt = connectedAt
        self.botNames = botNames
    }

    mutating func markUnknownVersion() { health = .unknownVersion }

    func sessionID(_ bot: String) -> String { "grokBot:\(accountScope):\(bot)" }
    private func event(_ kind: HookEvent.Kind, agent: Agent, now: Date, run: Run? = nil,
                       message: String? = nil, text: String? = nil, success: Bool? = nil) -> HookEvent {
        HookEvent(kind: kind, sessionID: sessionID(agent.id), agent: .grokBot,
                  sessionName: agent.name, message: message, waitKind: kind == .notification ? .question : nil,
                  observationSource: .gateway, timestamp: now, turnID: run?.nonce,
                  completionText: text, completionSucceeded: success,
                  sourceCompletionID: kind == .stop ? run.map { sessionID(agent.id) + ":" + $0.nonce } : nil)
    }

    mutating func baseline(_ agents: [Agent], now: Date, existingSessionIDs: Set<String> = [], tails: [String: [Entry]] = [:]) -> [HookEvent] {
        states.removeAll()
        return agents.filter { botNames == nil || botNames!.contains($0.name) }.prefix(128).flatMap { agent -> [HookEvent] in
            let tail = tails[agent.id] ?? []
            let latestUser = tail.last(where: { $0.kind == "message" && $0.role == "user" })?.timestampMs ?? 0
            let widget = !agent.isRunning ? tail.last(where: { $0.id == agent.lastMessageId && $0.direct && !$0.isStreaming && $0.unansweredWidget && ($0.timestampMs ?? 0) >= latestUser }) : nil
            states[agent.id] = State(agent: agent, completedNonce: agent.lastTurnSettlement?.clientNonce, widgetID: widget?.id ?? agent.widgetID)
            let waiting = agent.waiting || widget != nil
            if existingSessionIDs.contains(sessionID(agent.id)) {
                if waiting { return [event(.notification, agent: agent, now: now, message: "Respond in Grok Bot")] }
                if agent.isRunning { return [event(.userPromptSubmit, agent: agent, now: now)] }
                health = .eventsMissing
                return []
            }
            // sessionStart carries known idle state but never earns a completion.
            var events = [event(.sessionStart, agent: agent, now: now)]
            if waiting { events.append(event(.notification, agent: agent, now: now, message: "Respond in Grok Bot")) }
            else if agent.isRunning { events.append(event(.userPromptSubmit, agent: agent, now: now)) }
            return events
        }
    }

    mutating func receive(_ data: Data, now: Date) throws -> [HookEvent] {
        // Unrelated gateway channels can have arbitrary payload types. Decode only
        // supported channels after inspecting their string discriminator.
        struct Channel: Decodable { let channel: String }
        let decoder = JSONDecoder()
        let channel = try decoder.decode(Channel.self, from: data).channel
        guard channel == "agent-upserted" || channel == "transcript" else { return [] }
        let envelope: Envelope
        do { envelope = try decoder.decode(Envelope.self, from: data) }
        catch { health = .unknownVersion; return [] }
        guard let payload = envelope.payload else { throw GrokBotGatewayError.invalidResponse }
        if channel == "agent-upserted", let agent = payload.agent { return update(agent, now: now) }
        if channel == "transcript", let bot = payload.agentId, let entry = payload.entry {
            return transcript(entry, bot: bot, now: now)
        }
        // Whole-history snapshots are intentionally never interpreted as live turns.
        if channel == "transcript", payload.type == "snapshot" { return [] }
        throw GrokBotGatewayError.invalidResponse
    }

    private mutating func transcript(_ entry: Entry, bot: String, now: Date) -> [HookEvent] {
        guard var state = states[bot], entry.direct, !entry.isStreaming else { return [] }
        if entry.kind == "message", entry.role == "user", let nonce = entry.clientNonce, !nonce.isEmpty,
           nonce.utf8.count <= 256, nonce != state.completedNonce,
           let timestamp = entry.timestampMs, timestamp.isFinite,
           timestamp >= connectedAt.addingTimeInterval(-2).timeIntervalSince1970 * 1000 {
            if state.run?.nonce != nonce {
                health = .healthy
                state.completedAt = nil
                state.widgetID = nil
                state.run = Run(nonce: nonce, request: entry.requestId?.nonemptyGrokIdentity)
                states[bot] = state
                return [event(.userPromptSubmit, agent: state.agent, now: now, run: state.run)]
            }
            if let request = entry.requestId?.nonemptyGrokIdentity { state.run?.request = request }
        } else if entry.unansweredWidget, let request = entry.requestId?.nonemptyGrokIdentity,
                  request == state.run?.request {
            let fresh = state.widgetID != entry.id
            state.widgetID = entry.id
            state.run?.result = nil
            state.completedAt = nil
            states[bot] = state
            return fresh ? [event(.notification, agent: state.agent, now: now, run: state.run, message: "Respond in Grok Bot")] : []
        } else if entry.id == state.widgetID, entry.message?.type == "widget", entry.respondedValue != nil {
            // Answer continuation has a different request and no new nonce/settlement
            // in the verified protocol. Observe work, but never reuse the old success.
            state.widgetID = nil
            state.run = nil
            state.completedAt = nil
            health = .eventsMissing
            states[bot] = state
            return [event(.userPromptSubmit, agent: state.agent, now: now)]
        } else if entry.kind == "send-message", entry.message?.type == "text", let request = entry.requestId?.nonemptyGrokIdentity,
                  request == state.run?.request,
                  state.completedAt.map({ now <= $0.addingTimeInterval(2) }) ?? true,
                  let text = entry.message?.content,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 64_000 {
            state.run?.result = entry
        }
        states[bot] = state
        if !state.agent.isRunning, !state.agent.waiting, state.widgetID == nil,
           let completed = state.completedAt, now <= completed.addingTimeInterval(2),
           let run = state.run, run.nonce == state.completedNonce,
           let result = run.result, result.id == state.agent.lastMessageId,
           result.requestId == run.request {
            state.run?.result = nil
            states[bot] = state
            return [event(.stop, agent: state.agent, now: completed, run: run,
                          text: result.message?.content, success: true)]
        }
        return []
    }

    private mutating func update(_ agent: Agent, now: Date) -> [HookEvent] {
        guard botNames == nil || botNames!.contains(agent.name) else { return [] }
        guard var state = states[agent.id] else {
            guard states.count < 128 else { return [] }
            states[agent.id] = State(agent: agent, completedNonce: agent.lastTurnSettlement?.clientNonce)
            var events = [event(.sessionStart, agent: agent, now: now)]
            if agent.waiting { events.append(event(.notification, agent: agent, now: now, message: "Respond in Grok Bot")) }
            else if agent.isRunning { events.append(event(.userPromptSubmit, agent: agent, now: now)) }
            return events
        }
        // A coordinator epoch change invalidates cached text and turn evidence.
        if let old = state.agent.snapshotEpoch, let new = agent.snapshotEpoch, old != new {
            state.run = nil
            state.completedNonce = agent.lastTurnSettlement?.clientNonce
        } else if let old = state.agent.snapshotSeq, let new = agent.snapshotSeq, new <= old { return [] }
        let previous = state.agent
        let previouslyWaiting = previous.waiting || state.widgetID != nil
        if let widget = agent.widgetID { state.widgetID = widget }
        state.agent = agent
        defer { states[agent.id] = state }
        if (agent.waiting || agent.isRunning), state.completedAt != nil {
            state.run = nil
            state.completedAt = nil
        }
        if agent.waiting || state.widgetID != nil {
            return previouslyWaiting ? [] : [event(.notification, agent: agent, now: now, run: state.run, message: "Respond in Grok Bot")]
        }
        if agent.isRunning {
            return previous.isRunning && !previous.waiting ? [] : [event(.userPromptSubmit, agent: agent, now: now, run: state.run)]
        }
        guard previous.isRunning || previous.waiting, let run = state.run,
              let settlement = agent.lastTurnSettlement, settlement.clientNonce == run.nonce,
              settlement.clientNonce != state.completedNonce, settlement.settledAtMs.isFinite else {
            // Idle without a witnessed, identified turn is not a success signal.
            if previous.isRunning || previous.waiting { health = .eventsMissing }
            return []
        }
        guard let lastMessageID = agent.lastMessageId?.nonemptyGrokIdentity,
              agent.lastMessageType == "text" || run.result?.id == lastMessageID else {
            // Missing/unknown last-message metadata could hide a native question.
            // A success settlement alone cannot settle that ambiguity.
            health = .unknownVersion
            return []
        }
        guard settlement.outcome == "success" else {
            // Unverified error/abort subtype: no fabricated successful ending.
            health = .unknownVersion
            state.run = nil
            return []
        }
        let completed = Date(timeIntervalSince1970: settlement.settledAtMs / 1000)
        guard completed <= now.addingTimeInterval(2) else {
            health = .eventsMissing
            state.run = nil
            return []
        }
        health = .healthy
        state.completedNonce = run.nonce
        state.completedAt = completed
        let final = run.result
        // The downstream CompletionResults owns the frozen result and its TTL.
        // Keep only turn identity here once the source evidence is handed off.
        state.run?.result = nil
        let text = final?.id == agent.lastMessageId && final?.requestId == run.request ? final?.message?.content : nil
        return [event(.stop, agent: agent, now: completed, run: run, text: text, success: true)]
    }
}

private extension String {
    var nonemptyGrokIdentity: String? { !isEmpty && utf8.count <= 256 ? self : nil }
}
