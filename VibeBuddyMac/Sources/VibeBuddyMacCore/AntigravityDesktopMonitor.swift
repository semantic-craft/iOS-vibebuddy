import Foundation
import VibeBuddyKit

/// Read-only desktop observation. A missing source never becomes a stop event.
public actor AntigravityDesktopMonitor {
    private let client: AntigravityDesktopClient
    private let home: URL
    private let interval: Duration
    private var seen: [String: AntigravityDesktopObservation] = [:]
    private var tracked: Set<String> = []
    private var lastRead: [String: Date] = [:]
    private var registered: [String: AntigravityDesktopConversation] = [:]
    private var reported: [String: (ObservationHealth, Date)] = [:]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                client: AntigravityDesktopClient = AntigravityDesktopClient(), interval: Duration = .seconds(3)) {
        self.home = home; self.client = client; self.interval = interval
    }

    public func run(store: SessionStore) async {
        while !Task.isCancelled {
            await poll(store: store, now: Date())
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    public func poll(store: SessionStore, now: Date) async {
        let conversations: [AntigravityDesktopConversation]
        do { conversations = try await client.conversations() }
        catch {
            for id in tracked {
                await report(store, sessionID: id, health: .sourceUnreadable, at: now)
            }
            return
        }
        // Recent history is bounded; every live header is registered even if
        // its step read must wait for the next budgeted pass.
        let live = conversations.filter { $0.status.hasSuffix("RUNNING") }
        let liveIDs = Set(live.map(\.id))
        let selected = live + Array(conversations.filter { !liveIDs.contains($0.id) }.prefix(30))
        let present = Set(conversations.map(\.id))
        for id in tracked.subtracting(present) {
            await report(store, sessionID: id, health: .sourceUnreadable, at: now)
        }
        var pending: [AntigravityDesktopConversation] = []
        for conversation in selected {
            let known = registered[conversation.id]
            if known == nil || known?.title != conversation.title || known?.workspace != conversation.workspace || known?.source != conversation.source {
                await store.registerAntigravitySession(sessionID: conversation.id, source: conversation.source,
                    cwd: conversation.workspace, title: conversation.title, at: conversation.updatedAt ?? now)
                registered[conversation.id] = conversation
            }
            tracked.insert(conversation.id)
            if let previous = seen[conversation.id], previous.conversation == conversation,
               previous.state == .succeeded || previous.state == .cancelled || previous.state == .failed {
                await report(store, sessionID: conversation.id, health: .healthy, at: now)
                continue
            }
            pending.append(conversation)
        }
        pending.sort {
            let leftLive = liveIDs.contains($0.id), rightLive = liveIDs.contains($1.id)
            if leftLive != rightLive { return leftLive }
            return (lastRead[$0.id] ?? .distantPast) < (lastRead[$1.id] ?? .distantPast)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        var offset = 0
        while offset < pending.count, ContinuousClock.now < deadline, !Task.isCancelled {
            let batch = Array(pending[offset..<min(offset + 4, pending.count)])
            offset += batch.count
            let results = await withTaskGroup(of: (AntigravityDesktopConversation, AntigravityDesktopObservation?).self) { group in
                for conversation in batch {
                    group.addTask { [client] in
                        let result = try? await client.steps(for: conversation)
                        return (conversation, result?.observation(for: conversation))
                    }
                }
                var values: [(AntigravityDesktopConversation, AntigravityDesktopObservation?)] = []
                for await result in group { values.append(result) }
                return values
            }
            for (conversation, observation) in results {
                lastRead[conversation.id] = now
                guard let observation else {
                    await report(store, sessionID: conversation.id, health: .sourceUnreadable, at: now)
                    continue
                }
                await report(store, sessionID: conversation.id,
                    health: observation.state == .unknown ? .temporarilySilent : .healthy, at: now)
                let previous = seen[conversation.id]
                let missedBoundary = previous == nil || previous?.conversation.turnID != conversation.turnID
                if missedBoundary && [.succeeded, .cancelled, .failed].contains(observation.state) {
                    await store.reconcileAntigravityHistory(sessionID: conversation.id,
                        userStopped: observation.state == .cancelled, failed: observation.state == .failed, at: now,
                        replacesCompletedTurn: previous != nil && previous?.conversation.turnID != conversation.turnID)
                }
                for event in events(for: observation, now: now) { await store.ingest(event) }
            }
        }
        // Budget pressure is explicit uncertainty, never a silently omitted or
        // fabricated completed task. Oldest-read-first gives later rows a turn.
        for conversation in pending.dropFirst(offset) {
            await report(store, sessionID: conversation.id, health: .temporarilySilent, at: now)
        }
    }

    private func report(_ store: SessionStore, sessionID: String, health: ObservationHealth, at now: Date) async {
        if let previous = reported[sessionID], previous.0 == health, now.timeIntervalSince(previous.1) < 60 { return }
        reported[sessionID] = (health, now)
        await store.markAntigravityObservation(sessionID: sessionID, health: health, at: now)
    }

    /// Lifecycle seam shared by real polling and captured native-step replays.
    /// First-seen terminal records are history; only an observed transition can
    /// earn completion. Source turn identity makes repeats and recovery stable.
    public func events(for observation: AntigravityDesktopObservation, now: Date) -> [HookEvent] {
        let conversation = observation.conversation
        let before = seen[conversation.id]
        guard observation.state != .unknown else { return [] }
        seen[conversation.id] = observation
        let newTurn = before != nil && before?.conversation.turnID != conversation.turnID
        let changed = before?.state != observation.state || newTurn
        guard changed else { return [] }
        let live: Bool
        switch observation.state {
        case .working, .waiting: live = true
        default: live = false
        }
        var events: [HookEvent] = []
        if live && (before == nil || newTurn || before?.state == .succeeded || before?.state == .cancelled || before?.state == .failed) {
            events.append(event(.userPromptSubmit, observation, now: now))
        }
        switch observation.state {
        case .working:
            if events.isEmpty { events.append(event(.postToolUse, observation, now: now)) }
        case .waiting(let kind, let reason):
            events.append(event(.notification, observation, now: now, message: reason, wait: kind))
        case .succeeded, .cancelled, .failed:
            guard before != nil else { return [] }
            // Seeing a different already-ended historical turn is not a new
            // completion unless this monitor observed its active boundary.
            guard !newTurn else { return [] }
            let success = observation.state == .succeeded
            events.append(event(.stop, observation, now: now,
                message: success ? observation.finalText.map { String($0.prefix(220)) }
                    : (observation.state == .cancelled ? "Cancelled in Antigravity" : "Antigravity execution failed"),
                success: success))
        case .unknown: break
        }
        return events
    }

    private func event(_ kind: HookEvent.Kind, _ observation: AntigravityDesktopObservation, now: Date,
                       message: String? = nil, wait: WaitKind? = nil, success: Bool? = nil) -> HookEvent {
        let conversation = observation.conversation
        let turn = conversation.turnID ?? "steps-\(conversation.stepCount)"
        let logs = home.appendingPathComponent(".gemini/antigravity/brain")
            .appendingPathComponent(conversation.id).appendingPathComponent(".system_generated/logs")
        let full = logs.appendingPathComponent("transcript_full.jsonl")
        let short = logs.appendingPathComponent("transcript.jsonl")
        let path = FileManager.default.fileExists(atPath: full.path) ? full.path
            : (FileManager.default.fileExists(atPath: short.path) ? short.path : nil)
        return HookEvent(kind: kind, sessionID: conversation.id, agent: .antigravity,
            cwd: conversation.workspace, sessionName: conversation.title,
            message: message, waitKind: wait, transcriptPath: path, observationSource: .transcript,
            timestamp: now, turnID: conversation.turnID, turnStartedAt: Self.date(conversation.turnID),
            userStopped: kind == .stop && observation.state == .cancelled,
            completionText: success == true ? observation.finalText : nil, completionSucceeded: success,
            sourceCompletionID: kind == .stop ? "\(conversation.id):\(turn)" : nil)
    }
    private static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

}
