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
        while !Task.isCancelled {
            await poll(store: store, now: Date())
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// One deterministic pass: hand the store every agent it should know about,
    /// then the lifecycle events this pass justifies.
    public func poll(store: SessionStore, now: Date) async {
        let (agents, events) = await pass(now: now)
        guard let agents else { return }
        await store.applyCursorCloudAgents(agents)
        for event in events { await store.ingest(event) }
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
            seen[agent.id] = agent.status
            guard before != agent.status else { continue }
            switch agent.status {
            case .active:
                events.append(base(agent, kind: .userPromptSubmit, at: now, message: agent.name))
            case .idle:
                // Only a *transition* into idle is a completion. One that was
                // already idle when this process started finished before
                // vibebuddy was watching; it gets a history row instead, and
                // replaying it would ring for a run long since read.
                guard !first, before != nil else { continue }
                events.append(await completion(for: agent, at: now))
            case .archived:
                events.append(base(agent, kind: .sessionEnd, at: now))
            }
        }
        // An agent that left the list was archived or deleted in Cursor.
        for (id, status) in seen where !present.contains(id) {
            seen.removeValue(forKey: id)
            repositories.removeValue(forKey: id)
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
    /// The run detail is a second call, so failing to read it must not cost the
    /// completion: an unreadable run still ends the turn, just without the final
    /// text. `FINISHED` is the only run status that counts as success — `ERROR`,
    /// `CANCELLED` and `EXPIRED` all ended the turn without producing what was
    /// asked for.
    private func completion(for agent: CursorCloudAgent, at now: Date) async -> HookEvent {
        guard let runID = agent.latestRunID,
              let run = try? await client.run(agentID: agent.id, runID: runID) else {
            return base(agent, kind: .stop, at: now)
        }
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
