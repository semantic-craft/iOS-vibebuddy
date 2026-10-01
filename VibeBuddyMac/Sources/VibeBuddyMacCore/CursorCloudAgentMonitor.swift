import Foundation
import VibeBuddyKit

/// Polls Cursor's Cloud Agents API, which is where a cloud agent exists.
///
/// A cloud agent runs on Cursor's machines against a **GitHub repository**, not
/// on this Mac against a folder: no hook fires for it, no transcript is written
/// for it, and — checked against this machine's own Cursor database on
/// 2026-09-12 — no row appears for it in `composerHeaders` either. It has the
/// shape a Codex Desktop thread has (ADR-0011): a session with no local anchor,
/// whose only address is a URL. So the API does not *enrich* a local row here;
/// it is the row's only source.
///
/// ADR-0016's layer order is untouched for local Cursor conversations. It simply
/// has nothing to say about a conversation that never touches this Mac.
///
/// Two rules keep it honest:
///
/// - **It is a tail, not an import.** An agent already `IDLE` when vibebuddy
///   starts rings nothing — it finished before anyone was watching. It still
///   gets a quiet history row, the way an imported Copilot session does. An
///   agent already `ACTIVE` *is* reported live, because a run happening right
///   now is not history.
/// - **It is bounded.** Archived agents stay out and the list is capped, for the
///   same reason `cursorHistoryLimit` exists: a dashboard is the work in hand,
///   not an account archive.
public actor CursorCloudAgentMonitor {
    private let client: CursorCloudAgentClient
    private let interval: Duration
    private let limit: Int
    /// Last status seen per agent id. Absent means never seen by this process.
    private var seen: [String: CursorCloudAgentStatus] = [:]
    /// Repository per agent id. Only the per-agent endpoint carries it, and it
    /// cannot change for a given agent, so it is fetched once and kept.
    private var repositories: [String: String] = [:]
    private var started = false
    private var streams: [String: Task<Void, Never>] = [:]
    private var streamRuns: [String: String] = [:]
    private var cursors: [String: String] = [:]
    private var completed: [String: String] = [:]
    private var observedAgents: [String: CursorCloudAgent] = [:]
    /// The API health last handed to Settings diagnostics, and when.
    private var reported: (health: ObservationHealth, at: Date)?

    /// 20 seconds: fast enough that a cloud turn's end reaches the phone while
    /// the person still cares, slow enough to be three calls a minute on an
    /// endpoint Cursor documents no rate limit for. One list call covers every
    /// agent; run and agent detail are fetched only on a change.
    public init(client: CursorCloudAgentClient = CursorCloudAgentClient(),
                interval: Duration = .seconds(20),
                limit: Int = 50) {
        self.client = client
        self.interval = interval
        self.limit = limit
    }

    public func run(store: SessionStore) async {
        defer { for task in streams.values { task.cancel() }; streams.removeAll(); streamRuns.removeAll(); cursors.removeAll() }
        while !Task.isCancelled {
            await poll(store: store, now: Date())
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// One deterministic pass: hand the store every agent it should know about,
    /// then the lifecycle events this pass justifies.
    public func poll(store: SessionStore, now: Date) async {
        let (agents, events) = await pass(now: now)
        if client.isConfigured {
            await report(agents == nil ? .sourceUnreadable : .healthy, to: store, at: now)
        } else if reported != nil {
            // The key was removed: neither the last verdict nor its staleness
            // describes a source that is no longer set up.
            reported = nil
            await store.clearSourceSignal(agent: .cursor, source: .cloud)
        }
        guard let agents else { return }
        await store.applyCursorCloudAgents(agents)
        for event in events { await store.ingest(event) }
        reconcileStreams(agents: agents, store: store)
    }

    /// Whether the API answers, for Settings diagnostics. Sent on a change and
    /// otherwise every five minutes — inside the diagnostics' ten-minute
    /// staleness window, without a snapshot broadcast on every 20-second pass.
    private func report(_ health: ObservationHealth, to store: SessionStore, at now: Date) async {
        if let reported, reported.health == health, now.timeIntervalSince(reported.at) < 5 * 60 { return }
        reported = (health, now)
        await store.recordSourceSignal(agent: .cursor, source: .cloud, health: health, at: now)
    }

    /// The pure half, for tests: what this pass saw and what it justifies.
    /// A nil agent list means the pass failed and nothing should be applied —
    /// an unreachable API is not evidence that an agent stopped existing.
    public func pass(now: Date) async -> ([CursorCloudAgent]?, [HookEvent]) {
        guard client.isConfigured else { return ([], []) }
        let listed: [CursorCloudAgent]
        do {
            listed = try await client.agents(limit: limit)
        } catch {
            // A refused key, a rate limit or a dropped connection is not
            // evidence that anything finished. Rows keep the state this monitor
            // last established and the next pass retries.
            return (nil, [])
        }
        let first = !started
        started = true

        var agents: [CursorCloudAgent] = []
        var events: [HookEvent] = []
        var present: Set<String> = []
        for listing in listed {
            present.insert(listing.id)
            let agent = await withRepository(listing)
            agents.append(agent)
            let before = seen[agent.id]
            let previousRun = observedAgents[agent.id]?.latestRunID
            observedAgents[agent.id] = agent
            seen[agent.id] = agent.status
            if before == .active, agent.status == .active, previousRun == agent.latestRunID,
               completed[agent.id] != agent.latestRunID,
               let event = await completion(for: agent, at: now) { events.append(event) }
            guard before != agent.status || previousRun != agent.latestRunID else { continue }
            switch agent.status {
            case .active:
                events.append(base(agent, kind: .userPromptSubmit, at: now, message: agent.name))
            case .idle:
                // Only a *transition* into idle is a completion. One that was
                // already idle when this process started finished before
                // vibebuddy was watching; it gets a history row instead, and
                // replaying it would ring for a run long since read.
                guard !first, before != nil else { continue }
                if let event = await completion(for: agent, at: now) { events.append(event) }
                else if completed[agent.id] != agent.latestRunID { seen[agent.id] = before }
            case .archived:
                events.append(base(agent, kind: .sessionEnd, at: now))
            }
        }
        // An agent that left the list was archived or deleted in Cursor.
        for (id, status) in seen where !present.contains(id) {
            seen.removeValue(forKey: id)
            repositories.removeValue(forKey: id)
            observedAgents.removeValue(forKey: id)
            completed.removeValue(forKey: id)
            guard status != .archived else { continue }
            events.append(HookEvent(kind: .sessionEnd, sessionID: id, agent: .cursor,
                                    observationSource: .cloud, timestamp: now))
        }
        return (agents, events)
    }

    /// The repository an agent works on, fetched once. A failure is not worth a
    /// retry storm or a lost row: the agent simply keeps no repository until a
    /// later pass gets one.
    private func withRepository(_ agent: CursorCloudAgent) async -> CursorCloudAgent {
        if let known = repositories[agent.id] { return agent.naming(repository: known) }
        guard let detail = try? await client.agent(id: agent.id),
              let repository = detail.repository else { return agent }
        repositories[agent.id] = repository
        return agent.naming(repository: repository)
    }

    /// The end of a cloud turn, with whatever the run itself reported.
    ///
    /// A failed run read provides no terminal evidence; polling retries it.
    /// Only an authoritative terminal run ends the turn. `FINISHED` is the only run status that counts as success — `ERROR`,
    /// `CANCELLED` and `EXPIRED` all ended the turn without producing what was
    /// asked for.
    private func completion(for agent: CursorCloudAgent, at now: Date) async -> HookEvent? {
        guard let runID = agent.latestRunID,
              completed[agent.id] != runID,
              let run = try? await client.run(agentID: agent.id, runID: runID),
              run.id == runID, run.agentID == agent.id, !run.status.isLive else { return nil }
        // Recheck after the await: polling and the stream may read together.
        guard !Task.isCancelled, observedAgents[agent.id]?.latestRunID == runID,
              completed[agent.id] != runID else { return nil }
        completed[agent.id] = runID
        let succeeded = run.status == .finished
        let event = base(agent, kind: .stop, at: now,
                         message: run.result.map { String($0.prefix(220)) }
                            ?? (succeeded ? nil : "Run \(run.status.rawValue.lowercased())"),
                         completionText: succeeded ? run.result : nil,
                         completionSucceeded: succeeded,
                         enrichment: run.branch.map { TranscriptInfo(branch: $0) })
        // A run the person cancelled from here is an ending they asked for, not
        // a break — the same distinction the hook adapter draws for an aborted
        // Cursor turn.
        return run.status == .cancelled ? event.markingUserStop() : event
    }

    private func reconcileStreams(agents: [CursorCloudAgent], store: SessionStore) {
        let active = Dictionary(uniqueKeysWithValues: agents.filter { $0.status == .active && $0.latestRunID != nil }
            .map { ($0.id, $0.latestRunID!) })
        for id in Array(streamRuns.keys) where active[id] != streamRuns[id] {
            streams.removeValue(forKey: id)?.cancel()
            streamRuns.removeValue(forKey: id)
            cursors.removeValue(forKey: id)
        }
        for (id, runID) in active where streamRuns[id] == nil && completed[id] != runID {
            streamRuns[id] = runID
            streams[id] = Task { await self.follow(agentID: id, runID: runID, store: store) }
        }
    }

    private func follow(agentID: String, runID: String, store: SessionStore) async {
        var delay = 1
        while !Task.isCancelled && streamRuns[agentID] == runID && completed[agentID] != runID {
            do {
                try await client.stream(agentID: agentID, runID: runID, lastEventID: cursors[agentID]) { event in
                    try Task.checkCancellation()
                    await self.receive(event, agentID: agentID, runID: runID, store: store)
                }
            } catch CursorCloudError.service(let status, _) where status == 410 {
                // Retention expiry is not a completion. Stop retrying SSE and
                // read the authoritative run; polling keeps retrying that read.
                await terminal(agentID: agentID, runID: runID, store: store)
                return
            } catch { if Task.isCancelled { return } }
            guard completed[agentID] != runID else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            delay = min(delay * 2, 20)
        }
    }

    private func receive(_ event: CursorCloudStreamEvent, agentID: String, runID: String,
                         store: SessionStore) async {
        guard streamRuns[agentID] == runID, !Task.isCancelled else { return }
        // IDs are opaque and scoped to this run. result and done may share one.
        if let id = event.id { cursors[agentID] = id }
        guard ["status", "result", "done"].contains(event.kind) else { return }
        if event.kind != "done" {
            guard let bytes = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  json["runId"] as? String == runID,
                  let raw = json["status"] as? String,
                  let status = CursorCloudRun.Status(rawValue: raw), !status.isLive else { return }
        }
        await terminal(agentID: agentID, runID: runID, store: store)
    }

    private func terminal(agentID: String, runID: String, store: SessionStore) async {
        guard streamRuns[agentID] == runID, let agent = observedAgents[agentID],
              agent.latestRunID == runID, let event = await completion(for: agent, at: Date()) else { return }
        // completion claimed the run after its await. Cancellation after that
        // claim must not discard its one delivery; a changed run was rejected
        // before the claim, so this stop cannot target a newly observed run.
        await store.ingest(event)
        if streamRuns[agentID] == runID { streams[agentID]?.cancel() }
    }

    private func base(_ agent: CursorCloudAgent, kind: HookEvent.Kind, at now: Date,
                      message: String? = nil,
                      completionText: String? = nil,
                      completionSucceeded: Bool? = nil,
                      enrichment: TranscriptInfo? = nil) -> HookEvent {
        HookEvent(kind: kind, sessionID: agent.id, agent: .cursor,
                  cwd: agent.repository, sessionName: agent.name, message: message,
                  observationSource: .cloud, timestamp: now,
                  enrichment: enrichment,
                  completionText: completionText,
                  completionSucceeded: completionSucceeded)
    }
}

extension CursorCloudAgent {
    func naming(repository: String) -> CursorCloudAgent {
        CursorCloudAgent(id: id, name: name, status: status, environment: environment,
                         url: url, repository: repository, latestRunID: latestRunID,
                         updatedAt: updatedAt)
    }
}
