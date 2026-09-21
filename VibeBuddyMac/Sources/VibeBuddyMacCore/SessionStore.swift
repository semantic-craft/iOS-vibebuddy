import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads/subscriptions happen concurrently, so the mutable reducer lives behind
/// an actor. WebSocket clients subscribe for a live snapshot stream.
public actor SessionStore {
    private var contentPresenter = ContentPresentationService()
    private var presentationConfiguration: @Sendable () -> CompletionSummaryConfiguration = { .load() }
    private var savePresentationStyle: @Sendable (ContentStyleConfiguration) -> Bool = { style in
        UserDefaults.standard.set(style.customPrompt, forKey: ContentStyleConfiguration.customPromptKey)
        UserDefaults.standard.set(style.style.rawValue, forKey: ContentStyleConfiguration.defaultsKey)
        return true
    }
    private var recapPresentations: [String: ContentPresentation] = [:]
    private var recapCaptureTasks: [String: Task<Void, Never>] = [:]
    private var recapCaptureAttempts: Set<String> = []

    public func configureContentPresentation(service: ContentPresentationService,
        save: @escaping @Sendable (ContentStyleConfiguration) -> Bool = { _ in false },
        configuration: @escaping @Sendable () -> CompletionSummaryConfiguration) {
        contentPresenter = service
        presentationConfiguration = configuration
        savePresentationStyle = save
    }

    public func contentStyleState() -> ContentStyleState? {
        guard let sourceID else { return nil }
        let config = presentationConfiguration()
        return .init(sourceID: sourceID, configuration: config.contentStyle, revision: config.contentStyleStorageRevision)
    }

    public func updateContentStyle(_ update: ContentStyleUpdate) -> ContentStyleState? {
        guard update.sourceID == sourceID, update.expectedRevision == presentationConfiguration().contentStyleStorageRevision,
              update.configuration.customPrompt.count <= ContentStyleConfiguration.maximumCustomPromptCharacters,
              update.configuration.style != .custom || !update.configuration.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        guard savePresentationStyle(update.configuration) else { return nil }
        recapPresentations.removeAll()
        broadcast()
        return contentStyleState()
    }

    public func presentation(_ request: ContentPresentationRequest) async -> ContentPresentation? {
        guard request.sourceID == sourceID else {
            ContentPresentationService.diagnose(stage: "target", reason: "sourceMismatch")
            return nil
        }
        guard presentationTargetIsCurrent(request) else {
            ContentPresentationService.diagnose(stage: "target", reason: "staleOrRejectedEvidence")
            return nil
        }
        let config = presentationConfiguration()
        var input = await presentationInput(request)
        if request.purpose == .speech, case .completion = request.target {
            for _ in 0..<8 {
                if input != nil, await speechEvidenceIsSettled(request) { break }
                guard !Task.isCancelled, presentationTargetIsCurrent(request) else { return nil }
                try? await Task.sleep(for: .milliseconds(250))
                input = await presentationInput(request)
            }
            guard input != nil, await speechEvidenceIsSettled(request) else { return nil }
        }
        let text: String?
        if let input {
            text = await contentPresenter.generate(input, purpose: request.purpose, configuration: config)
        } else { text = nil }
        if request.purpose == .speech, case .completion = request.target,
           !(await speechEvidenceIsSettled(request)) { return nil }
        guard !Task.isCancelled, presentationTargetIsCurrent(request) else {
            ContentPresentationService.diagnose(stage: "target", reason: "cancelledOrChangedDuringGeneration")
            return nil
        }
        guard config.presentationRevision == presentationConfiguration().presentationRevision else {
            ContentPresentationService.diagnose(stage: "configuration", reason: "changedDuringGeneration")
            return nil
        }
        var spokenText = text ?? presentationFallback(request, language: config.language)
        if request.purpose == .speech, let title = input?.title, !spokenText.contains(title) {
            spokenText = title + (config.language == .chinese ? "。" : ". ") + spokenText
        }
        let result = ContentPresentation(request: request, revision: config.presentationRevision,
            text: spokenText, generated: text != nil)
        if case .recap(let id) = request.target, result.generated {
            recapPresentations[id] = result
            if recapPresentations.count > Recap.maxEntries * 2 {
                let visible = Set(recapLedger.entries.keys)
                recapPresentations = recapPresentations.filter { visible.contains($0.key) }
                if recapPresentations.count > Recap.maxEntries * 2 { recapPresentations = [id: result] }
            }
            broadcast()
        }
        return result
    }

    private func presentationTargetIsCurrent(_ request: ContentPresentationRequest) -> Bool {
        guard request.sourceID == sourceID else { return false }
        switch request.target {
        case .recap(let id):
            guard request.purpose == .recap, let entry = recapLedger.entries[id],
                  entry.endedAt > Date().addingTimeInterval(-RecapLedger.retention), entry.resultConflict != true else { return false }
            return entry.completionID.map { !resultRejected(sessionID: entry.sessionID, completionID: $0) } ?? true
        case .completion(let id, _), .waiting(let id, _, _, _), .failure(let id, _):
            guard request.purpose == .speech, let session = reducer.sessions[id], session.historyOnly != true else { return false }
            guard request.target.matches(session) else { return false }
            if case .completion(_, let completionID) = request.target {
                return !resultRejected(sessionID: id, completionID: completionID)
            }
            return true
        }
    }

    private func presentationInput(_ request: ContentPresentationRequest) async -> CompletionSummaryInput? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sessionID: String, identity: String, title: String, material: String
        switch request.target {
        case .recap(let id):
            if let entry = recapLedger.entries[id], entry.resultText == nil, let completionID = entry.completionID {
                await captureRecapResult(id: id, sessionID: entry.sessionID, completionID: completionID)
            }
            guard let entry = recapLedger.entries[id], entry.resultConflict != true,
                  presentationTargetIsCurrent(request), let original = entry.resultText, !original.isEmpty else {
                ContentPresentationService.diagnose(stage: "evidence", reason: "recapResultUnavailable")
                return nil
            }
            sessionID = entry.sessionID; identity = id
            title = entry.title
            material = "Historical round ended at \(entry.endedAt). Outcome: \(entry.kind.rawValue). Current state has not been checked.\n" + original
        case .completion(let id, let completionID):
            guard let session = reducer.sessions[id] else { return nil }
            let body = await completionBody(sessionID: id, completionID: completionID)
            guard body.sourceID == request.sourceID, body.completionID == completionID, let original = body.text, !original.isEmpty else {
                ContentPresentationService.diagnose(stage: "evidence", reason: body.unavailableReason ?? "resultUnavailable")
                return nil
            }
            sessionID = id; identity = completionID
            title = session.displayTitle
            material = "This round ended. The final answer reports the following; ending is not proof of project completion.\n" + original
        case .waiting(let id, _, _, _), .failure(let id, _):
            guard let session = reducer.sessions[id] else { return nil }
            sessionID = id
            identity = String(decoding: (try? encoder.encode(request.target)) ?? Data(), as: UTF8.self)
            title = session.displayTitle
            if session.status == .needsResponse {
                let question = session.pendingQuestion.flatMap { try? encoder.encode($0) }
                let approval = session.pendingApproval.flatMap { try? encoder.encode($0) }
                let evidence = question ?? approval
                material = "Current status: waiting for user \(session.waitKind?.rawValue ?? "response"). Describe the requested choice, benefits and costs only when supported.\n"
                    + (evidence.map { String(decoding: $0, as: UTF8.self) } ?? session.summary ?? "No request details available.")
            } else {
                material = "Current status: stopped with a confirmed failure. Do not invent a repair or request approval.\n" + (session.summary ?? "Failure details unavailable.")
            }
        }
        let now = Date()
        return CompletionSummaryInput(sourceID: request.sourceID, sessionID: sessionID,
            completionID: identity, title: title, finalText: material, completedAt: now, observedAt: now)
    }

    private func presentationFallback(_ request: ContentPresentationRequest, language: VoiceLanguage) -> String {
        let chinese = language == .chinese
        switch request.target {
        case .recap:
            return chinese ? "这一轮暂时无法生成当前风格的摘要。请查看保存的原记录。" : "A summary in the current style is unavailable. Review the saved record."
        case .completion(let id, _), .waiting(let id, _, _, _), .failure(let id, _):
            guard let session = reducer.sessions[id] else { return "" }
            let title = session.displayTitle
            if session.status == .needsResponse {
                return chinese ? "\(title)，请打开任务查看待你决定的事项。当前无法生成详细摘要。" : "\(title). Open the task to review the pending decision. A detailed summary is unavailable."
            }
            if session.isStuck {
                return chinese ? "\(title)，任务因问题停止。请打开任务查看原因。" : "\(title). The task stopped with an issue. Open it to review the cause."
            }
            if case .completion(_, let completionID) = request.target,
               let key = resultKey(sessionID: id, completionID: completionID),
               let excerpt = completionResults.resultExcerpt(key: key) {
                return chinese ? "\(title)，结果摘录：\(excerpt)" : "\(title). Result excerpt: \(excerpt)"
            }
            return ""
        }
    }

    private func speechEvidenceIsSettled(_ request: ContentPresentationRequest) async -> Bool {
        guard case .completion(let sessionID, let completionID) = request.target,
              let key = resultKey(sessionID: sessionID, completionID: completionID),
              let read = completionResults.speechRead(key: key,
                  cursorFollowupHandedAt: cursorFollowupHandedAt[sessionID]) else { return false }
        return await Task.detached { read.speechEvidenceIsSettled() }.value
    }

    private func captureRecapResult(id: String, sessionID: String, completionID: String) async {
        guard id == resultKey(sessionID: sessionID, completionID: completionID), recapLedger.entries[id] != nil,
              let result = await readCompletionRecord(key: id), !Task.isCancelled else { return }
        recapLedger.retainResult(id: id, text: result.finalText, now: Date())
    }

    private static let diagnosticStaleAfter: TimeInterval = 10 * 60
    // Discovery/reachability is not proof that this connection carries progress.
    private var appServerProgressAt: [String: Date] = [:]
    private var activeCodexRollouts: Set<String> = []
    private var codexThreadNames = CodexThreadNames()
    private var cursorFollowupHandedAt: [String: Date] = [:]
    private var reducer = SessionReducer()
    private var toolLedger: ToolLedger
    private var workingDirectories: [String: String] = [:]
    private var copilotReader: CopilotSessionReader
    private var copilotReadFailed = false
    private var copilotHistory: [String: CopilotSessionReader.Record] = [:]
    private var cursorStore: CursorComposerStore
    private var cursorReadFailed = false
    /// Cursor's own record of every conversation, keyed by composer id. Live
    /// rows read facts out of it; conversations with no live evidence become
    /// history rows.
    private var cursorComposers: [String: CursorComposer] = [:]
    /// Cursor conversations whose `sessionStart` said `composer_mode` is `ask`
    /// or `edit`. Such a chat is a question and an answer, not a task: it must
    /// not enter the three states, mint a completion or ring a cue, so every
    /// event for it — from the hook *and* from the transcript tailer, since
    /// both key on the same conversation id — is dropped before the reducer.
    /// `sessionEnd` releases the id. The set is memory-only: a chat that was
    /// Ask before a daemon restart re-announces its mode on its next start.
    private var cursorObserveOnly: Set<String> = []
    /// Per Cursor conversation, the dialogue the hooks themselves carried —
    /// prompts, replies, tool markers and tool *results*. The agent transcript
    /// records no tool results, so while the hooks are live this is the richer
    /// recent-output source; bounded like every other slice.
    private var cursorHookLog: [String: [TranscriptEntry]] = [:]
    static let cursorHookLogLimit = 24
    /// Cursor conversations the ACP host is carrying right now. While one is,
    /// that pipe is the live source and the write path: hook and transcript
    /// events for the same id only corroborate, the hook gate says nothing, and
    /// the row is stamped `ControlChannel.acp`. Memory-only: the processes die
    /// with the daemon, so nothing here outlives it either.
    private var acpHosted: Set<String> = []
    private var acpRecoveryRows: [String: AgentSession] = [:]

    public func registerACPRecovery(sessionID: String, cwd: String, model: String?, unavailable: String?, updatedAt: Date, retryable: Bool = false) {
        var row = AgentSession(id: sessionID, agent: .cursor, project: cwd, checkoutPath: cwd,
                               model: model, status: .done, summary: "Managed Cursor session; reconnects on continue",
                               statusSince: updatedAt, updatedAt: updatedAt)
        row.historyOnly = true
        row.cursorACPRecoverable = true
        row.cursorACPRecoveryUnavailable = retryable ? nil : unavailable
        row.cursorACPRecoveryFailure = retryable ? unavailable : nil
        acpRecoveryRows[sessionID] = row
        broadcast()
    }

    /// The ACP host took over (or let go of) a conversation.
    public func setACPHosted(sessionID: String, _ hosted: Bool) {
        let changed = hosted ? acpHosted.insert(sessionID).inserted : acpHosted.remove(sessionID) != nil
        if changed { broadcast() }
    }

    public func isACPHosted(_ sessionID: String) -> Bool { acpHosted.contains(sessionID) }

    /// A queued follow-up left for Cursor: through its `stop` hook (which says
    /// how many automatic follow-ups this conversation has already taken, so a
    /// silent drop past a `loop_limit` can be seen in the journal) or as the
    /// ACP host's next prompt.
    public func noteCursorFollowupHandoff(sessionID: String, loopCount: Int?, source: ObservationSource, at date: Date) {
        cursorFollowupHandedAt[sessionID] = date
        let event = loopCount.map { "cursorFollowupHandedOver(loop \($0))" } ?? "cursorFollowupHandedOver"
        _ = appendJournal(sessionID: sessionID, agent: .cursor, event: event, source: source, at: date)
    }

    /// The write path the daemon would use for this session, stamped on every
    /// snapshot so the phone and the Watch decide availability from one fact
    /// (ADR-0016, second amendment). Codex: the app-server while it is fresh.
    /// Cursor: the ACP host it lives on, else the cloud API that reports it,
    /// else its hooks while they are fresh, else nothing reachable. Other
    /// agents carry no stamp and keep their agent-based rules.
    func controlChannel(for session: AgentSession, now: Date) -> ControlChannel? {
        func fresh(_ source: ObservationSource, within window: TimeInterval) -> Bool {
            guard let evidence = session.observations?.first(where: { $0.source == source }),
                  evidence.health.isHealthy else { return false }
            return now.timeIntervalSince(evidence.lastObservedAt) < window
        }
        switch session.agent {
        case .codex:
            return fresh(.appserver, within: Self.appServerAuthorityWindow) ? .appserver : nil
        case .cursor:
            if acpHosted.contains(session.id) { return .acp }
            if acpRecoveryRows[session.id] != nil { return ControlChannel.none }
            if session.observations?.contains(where: { $0.source == .cloud && $0.health.isHealthy }) == true { return .cloud }
            if fresh(.hook, within: Self.cursorHookAuthorityWindow) { return .hook }
            return ControlChannel.none
        case .grok:
            // A Grok Build session vibebuddy hosts over ACP (ADR-0030) is the
            // only Grok write path; a session seen through hooks alone keeps
            // the agent's rule (no stamp: the phone says "use the terminal").
            return acpHosted.contains(session.id) ? .acp : nil
        default:
            return nil
        }
    }

    /// History bypasses the lifecycle reducer: imports never earn completion cues.
    public func refreshCopilotHistory() {
        do {
            guard let records = try copilotReader.refresh() else { return }
            let next = Dictionary(records.map { ($0.session.id, $0) }, uniquingKeysWith: { _, last in last })
            let recovered = copilotReadFailed
            copilotReadFailed = false
            guard next != copilotHistory || recovered else { return }
            copilotHistory = next
            broadcast()
        } catch {
            if !copilotReadFailed {
                copilotReadFailed = true
                broadcast()
            }
            // Retain readable history through a transient lock or incompatible schema.
            // A failed read never advances the scanner signature; the next poll retries.
        }
    }
    /// Cursor's conversation index. Two jobs in one pass: fill in what hooks
    /// and transcripts never carry (the chat's own name, the tracked branch, the
    /// model, the real context window), and give a row to conversations that are
    /// only history. Never moves the three states — Cursor's `status` says what
    /// *it* thinks, and a live source outranks a database written a beat late.
    public func refreshCursorComposers() {
        var changed = false
        do {
            if let composers = try cursorStore.refresh() {
                let next = Dictionary(composers.filter { !$0.isSubagent && $0.hasRun }
                    .map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                changed = next != cursorComposers || cursorReadFailed
                cursorComposers = next
            }
            cursorReadFailed = false
        } catch {
            if !cursorReadFailed {
                cursorReadFailed = true
                changed = true
            }
            // Keep the last readable index through a transient lock or a schema
            // Cursor changed; the next poll retries from an unchanged signature.
        }
        // Always re-apply: the index is usually *older* than the live row it
        // belongs to (a conversation is read from the database long before, or
        // long after, a hook first reports it), so waiting for the file to
        // change would leave a session that appeared in between un-named.
        if applyCursorFacts() || changed { broadcast() }
    }

    /// Copy Cursor's facts onto the live rows that already exist. Enrichment
    /// only: status, waits and completions stay with the live sources. Returns
    /// whether any row actually changed, so an unchanged pass is silent.
    @discardableResult
    private func applyCursorFacts() -> Bool {
        var changed = false
        for composer in cursorComposers.values {
            guard let before = reducer.sessions[composer.id] else { continue }
            if reducer.applyCursorComposer(composer) { changed = true }
            enrichSession(sessionID: composer.id, with: TranscriptInfo(
                model: composer.model,
                contextTokens: composer.contextTokens,
                contextWindow: composer.contextWindow,
                branch: composer.branch))
            if reducer.sessions[composer.id] != before { changed = true }
        }
        return changed
    }

    /// Cursor's cloud agents, keyed by agent id, as the Cloud Agents API last
    /// reported them. Unlike the composer store this *is* the source for these
    /// conversations: they run on Cursor's machines and appear nowhere on this
    /// Mac — not in `composerHeaders`, not as a transcript, not as a hook.
    private var cursorCloudAgents: [String: CursorCloudAgent] = [:]

    /// Take the monitor's view of the account. Rows with no live session become
    /// quiet history rows; rows the monitor has moved into the three states keep
    /// whatever the reducer holds.
    public func applyCursorCloudAgents(_ agents: [CursorCloudAgent]) {
        let next = Dictionary(agents.filter { $0.status != .archived }.map { ($0.id, $0) },
                              uniquingKeysWith: { _, last in last })
        guard next != cursorCloudAgents else { return }
        cursorCloudAgents = next
        broadcast()
    }

    /// Where a cloud agent can actually be opened. It has no window on this Mac
    /// and no terminal, so its Cursor web page is the only honest jump — the
    /// same shape as a Codex Desktop thread's.
    public func cursorCloudAgentURL(for sessionID: String) -> String? {
        cursorCloudAgents[sessionID]?.url
    }

    /// The run a stop would cancel. Nil when the agent is not live, which is
    /// also when there is nothing to cancel.
    public func cursorCloudLatestRun(for sessionID: String) -> String? {
        guard let agent = cursorCloudAgents[sessionID], agent.status == .active else { return nil }
        return agent.latestRunID
    }

    /// How many cloud agents get a history row, for the same reason
    /// `cursorHistoryLimit` exists.
    static let cursorCloudHistoryLimit = 50

    /// A cloud agent vibebuddy has only ever seen finished: a quiet history row
    /// that never earns a completion cue, exactly like an imported Copilot
    /// session. Its repository stands in for a project, because it has no folder.
    private func cursorCloudHistorySessions() -> [AgentSession] {
        cursorCloudAgents.values
            .filter { reducer.sessions[$0.id] == nil }
            .sorted { lhs, rhs in
                let left = lhs.updatedAt ?? .distantPast, right = rhs.updatedAt ?? .distantPast
                return left == right ? lhs.id < rhs.id : left > right
            }
            .prefix(Self.cursorCloudHistoryLimit)
            .map { agent in
                let when = agent.updatedAt ?? Date()
                var session = AgentSession(
                    id: agent.id, agent: .cursor,
                    project: agent.repository ?? String(localized: "Cursor cloud agent"),
                    status: .done, name: agent.name,
                    statusSince: when, updatedAt: when)
                session.historyOnly = true
                return session
            }
    }

    /// How many of Cursor's stored conversations get a history row. Cursor keeps
    /// every chat until its own cleanup prunes them, and a dashboard is a list of
    /// work in progress, not an archive.
    static let cursorHistoryLimit = 50

    /// A Cursor conversation vibebuddy only knows from Cursor's database: shown
    /// the way an imported Copilot session is, as a quiet history row that never
    /// earns a completion cue. A chat the person archived in Cursor is one they
    /// filed away, so it stays out.
    private func cursorHistorySessions() -> [AgentSession] {
        cursorComposers.values
            .filter { !$0.isArchived && reducer.sessions[$0.id] == nil }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
            .prefix(Self.cursorHistoryLimit)
            .map { composer in
                var session = AgentSession(
                    id: composer.id, agent: .cursor,
                    project: composer.project ?? String(localized: "Cursor chat"),
                    branch: composer.branch, model: composer.model, status: .done,
                    summary: composer.subtitle, contextTokens: composer.contextTokens,
                    contextWindow: composer.contextWindow,
                    name: composer.name,
                    statusSince: composer.updatedAt, updatedAt: composer.updatedAt)
                session.historyOnly = true
                return session
            }
    }

    private var noticeLedger: CompletionNoticeLedger?
    private var noticeEnabled: (@Sendable () -> Bool)?
    private var noticeHandler: (@Sendable (AgentSession) async -> String?)?
    private var noticeTasks: [String: Task<Void, Never>] = [:]

    public func configureCompletionNotices(url: URL, enabled: @escaping @Sendable () -> Bool,
        generate: @escaping @Sendable (AgentSession) async -> String?) {
        noticeLedger = CompletionNoticeLedger(url: url)
        noticeEnabled = enabled
        noticeHandler = generate
    }

    private func completionNotice(for session: AgentSession, now: Date) -> CompletionNotice? {
        guard let sourceID, let completionID = session.completionID, noticeLedger != nil else { return nil }
        let id = sourceID + "/" + session.id + "/" + completionID
        let eligible = session.status == .done && session.hasUnreadCompletion && !session.isStuck
            && !resultRejected(sessionID: session.id, completionID: completionID)
            && session.effectiveAttention == .followed && noticeEnabled?() == true
        if var existing = noticeLedger?.notices[id] {
            if existing.state == .pending && !eligible {
                existing.state = .cancelled
                _ = noticeLedger?.save(existing)
                noticeTasks.removeValue(forKey: id)?.cancel()
            }
            return existing
        }
        guard eligible, [.claudeCode, .codex, .cursor].contains(session.agent),
              now < session.statusSince.addingTimeInterval(12), let handler = noticeHandler else { return nil }
        var notice = CompletionNotice(id: id, deadline: session.statusSince.addingTimeInterval(12))
        let contentConfig = presentationConfiguration()
        notice.contentStyle = contentConfig.contentStyle.style
        notice.presentationRevision = contentConfig.presentationRevision
        guard noticeLedger?.save(notice) == true else { return nil }
        noticeTasks[id] = Task {
            let request = ContentPresentationRequest(sourceID: sourceID,
                target: .completion(sessionID: session.id, completionID: completionID), purpose: .speech)
            while !Task.isCancelled, Date() < notice.deadline, self.presentationTargetIsCurrent(request) {
                let body = await self.completionBody(sessionID: session.id, completionID: completionID)
                if body.text != nil, await self.speechEvidenceIsSettled(request) {
                    guard !Task.isCancelled, self.presentationTargetIsCurrent(request) else { return }
                    let text = await handler(session)
                    await self.finishCompletionNotice(id: id, sessionID: session.id, completionID: completionID, text: text)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            await self.finishCompletionNotice(id: id, sessionID: session.id, completionID: completionID, text: nil)
        }
        Task {
            try? await Task.sleep(for: .seconds(max(0, notice.deadline.timeIntervalSinceNow)))
            await self.finishCompletionNotice(id: id, sessionID: session.id, completionID: completionID, text: nil)
        }
        return notice
    }

    private func finishCompletionNotice(id: String, sessionID: String, completionID: String, text: String?) async {
        guard let sourceID else { return }
        let body = await completionBody(sessionID: sessionID, completionID: completionID)
        let settled: Bool
        if body.text != nil {
            settled = await speechEvidenceIsSettled(.init(sourceID: sourceID,
                target: .completion(sessionID: sessionID, completionID: completionID), purpose: .speech))
        } else { settled = false }
        guard var notice = noticeLedger?.notices[id], notice.state == .pending else { return }
        let session = reducer.sessions[sessionID]
        let followed = (attention[sessionID] ?? AutoAttention.level(lastInteractionAt: lastInteractionAt[sessionID], now: Date())) == .followed
        let valid = settled && !resultRejected(sessionID: sessionID, completionID: completionID)
            && session?.status == .done && session?.completionID == completionID
            && session?.hasUnreadCompletion == true && session?.isStuck == false && followed && noticeEnabled?() == true
            && (notice.presentationRevision == nil || notice.presentationRevision == presentationConfiguration().presentationRevision)
        if !valid { notice.state = .cancelled }
        else if Date() < notice.deadline, let text, !text.isEmpty, text.count <= 180 {
            notice.state = .summary; notice.text = text
        } else { notice.state = .plain }
        if noticeLedger?.save(notice) != true {
            notice.state = valid ? .plain : .cancelled; notice.text = nil
            noticeLedger?.notices[id] = notice
        }
        noticeTasks.removeValue(forKey: id)?.cancel()
        broadcast()
    }

    private var completionResults = CompletionResults()
    private var completionReads: Set<String> = []
    public let sourceID: String?
    /// Account allowance, kept beside the reducer rather than inside it.
    private var providerQuota: [ProviderQuota] = []
    /// Local token spend, kept beside the reducer rather than inside it.
    private var tokenConsumption: TokenConsumptionSnapshot?
    /// Models the signed-in Cursor CLI lists, for a Cursor dispatch.
    private var cursorModels: [String] = []
    /// The agents `/dispatch` can start, as last computed by the server. Kept
    /// here so the WebSocket snapshots carry it too — without it the phone
    /// received the list only from `GET /snapshot`, and every push afterwards
    /// emptied it, so the New task sheet lost its agent switcher.
    private var dispatchAgents: [AgentKind] = []
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var needsResponseHandler: (@Sendable (AgentSession) async -> Void)?
    private var staleAfter: TimeInterval
    /// Per-session transcript path, remembered so `sweep` can check whether a
    /// waiting session's transcript advanced (i.e. the prompt was answered).
    private var transcriptPaths: [String: String] = [:]
    private enum ExplicitWait: Equatable {
        case question(String)
        case approval(String)

        func matches(_ session: AgentSession) -> Bool {
            switch self {
            case .question(let id): return session.pendingQuestion?.id == id
            case .approval(let id): return session.pendingApproval?.id == id
            }
        }
    }
    /// Only waits delivered through beginQuestion/beginApproval, never inferred prose.
    private var explicitWaits: [String: ExplicitWait] = [:]
    /// Terminal refs remembered by session id, so a `/terminal` POST that races
    /// ahead of the session-creating `SessionStart` still lands once it exists.
    private var pendingTerminalRefs: [String: TerminalRef] = [:]
    /// Resolved `~/.grok/sessions/<cwd>/<id>` directories. Grok's hook envelope
    /// names no transcript on every event, and the fallback is a directory
    /// scan, so the answer is remembered for the life of the session.
    private var grokDirectories: [String: URL] = [:]
    /// Grok's own data directory (`$GROK_HOME`, else `~/.grok`), not the user's
    /// home: the session store is rooted at `<grok home>/sessions`.
    private let grokHome: URL
    private let diagnosticsHome: URL?
    private var runtimeSignals: [AgentKind: [ObservationSource: ObservationRuntimeSignal]] = [:]
    private var diagnosticCache: (at: Date, value: [AgentObservationDiagnostic])?
    private var lifecycleJournal: LifecycleJournal?
    /// Missed `needsResponse` waits (Q13). Beside the journal; muted counts.
    private var missedLedger: MissedLedger
    /// Ended rounds and the recap horizon, beside the journal (`RecapLedger`).
    private var recapLedger: RecapLedger
    private var handoffScanner: HandoffScanner
    /// Who continued whom, beside the journal (`ContinuationLedger`); a
    /// session's `continuesSessionKey` and a handoff's `takenBy` derive from it.
    private var continuationLedger: ContinuationLedger
    /// Where sessions ran, beside the journal (`RecentDirectories`): the
    /// directories a task may start in and each session's observed checkout.
    private var recentDirectoryLedger: RecentDirectories

    /// Continue with… started `receiverKey` to carry on `sourceKey`, from the
    /// handoff at `handoffPath` when there was one. Written by the dispatch
    /// layer once the receiver exists; survives a restart for seven days.
    public func recordContinuation(receiverKey: String, sourceKey: String, handoffPath: String?, now: Date = Date()) {
        continuationLedger.record(receiverKey: receiverKey, sourceKey: sourceKey, handoffPath: handoffPath, now: now)
        broadcast()
    }
    /// The user's hand-set attention levels, layered onto every snapshot.
    private var attention: AttentionOverrides
    /// When the user last drove each session (prompt, jump, decision, answer);
    /// what `AutoAttention` reads when there is no hand-set level.
    private var lastInteractionAt: [String: Date] = [:]

    public init(
        staleAfter: TimeInterval = 2 * 60 * 60,
        sourceID: String? = UUID().uuidString,
        diagnosticsHome: URL? = nil,
        journalURL: URL? = nil,
        attentionURL: URL? = nil,
        missedURL: URL? = nil,
        grokHome: URL? = nil,
        copilotDatabase: URL? = nil,
        cursorDatabase: URL? = nil,
        now: Date = Date()
    ) {
        self.copilotReader = copilotDatabase.map { CopilotSessionReader(database: $0) } ?? CopilotSessionReader()
        self.cursorStore = cursorDatabase.map { CursorComposerStore(database: $0) } ?? CursorComposerStore()
        self.toolLedger = ToolLedger(url: journalURL?.deletingLastPathComponent().appendingPathComponent("tool-ledger.json"), now: now)
        self.recapLedger = RecapLedger(url: journalURL?.deletingLastPathComponent().appendingPathComponent("recap-ledger.json"), now: now)
        self.completionResults = CompletionResults(restoring: self.recapLedger)
        self.handoffScanner = HandoffScanner()
        let ledgerDirectory = journalURL?.deletingLastPathComponent()
        self.continuationLedger = ContinuationLedger(url: ledgerDirectory?.appendingPathComponent(ContinuationLedger.fileName), now: now)
        self.recentDirectoryLedger = RecentDirectories(url: ledgerDirectory?.appendingPathComponent("recent-directories.json"), now: now)
        self.sourceID = sourceID
        self.staleAfter = staleAfter
        self.diagnosticsHome = diagnosticsHome
        self.grokHome = grokHome ?? GrokHome.url
        if let journalURL {
            let journal = LifecycleJournal(url: journalURL, now: now)
            self.lifecycleJournal = journal
            reducer.restore(journal.restorableSessions(now: now, meaningfulFor: staleAfter))
            // A restored session gets the checkout it was actually observed in,
            // or none; a folder with the same name is not evidence.
            for id in reducer.sessions.keys {
                guard let checkout = recentDirectoryLedger.checkout(of: id) else { continue }
                reducer.restoreCheckout(sessionID: id, path: checkout)
                workingDirectories[id] = checkout
            }
        }
        var missed = MissedLedger(url: missedURL, now: now)
        missed.observe(Array(reducer.sessions.values), now: now)
        self.missedLedger = missed
        var attention = AttentionOverrides(url: attentionURL)
        attention.prune(keeping: Set(reducer.sessions.keys))
        self.attention = attention
    }

    /// Set (or with `nil` clear) the user's attention choice for a live session.
    /// Returns false when no such session exists — there is nothing to attach
    /// the choice to, and it would never be pruned.
    @discardableResult
    public func setAttention(sessionID: String, _ level: SessionAttention?) -> Bool {
        guard reducer.sessions[sessionID] != nil else { return false }
        attention.set(level, for: sessionID)
        broadcast()
        return true
    }

    /// The user just acted on this session — typed a prompt, jumped to it,
    /// decided its approval, answered its question. Keeps it `followed` for
    /// `AutoAttention.window` unless a hand-set level says otherwise.
    public func recordInteraction(sessionID: String, at: Date = Date()) {
        guard reducer.sessions[sessionID] != nil else { return }
        lastInteractionAt[sessionID] = at
        cancelMissedWait(sessionID: sessionID, now: at)
        broadcast()
    }

    /// Change the idle-cleanup window at runtime (from Settings).
    public func setStaleAfter(_ interval: TimeInterval) { staleAfter = interval }

    /// Self-heal: drop `needsResponse` sessions that are answered (transcript
    /// advanced past `statusSince`) or abandoned (idle past `staleAfter`), even
    /// when their terminal hook was never received. Broadcasts if anything changed.
    public func sweep(now: Date) {
        explicitWaits = explicitWaits.filter { id, wait in
            reducer.sessions[id].map(wait.matches) == true
        }
        var lastActivity: [String: Date] = [:]
        for (id, session) in reducer.sessions where session.status == .needsResponse {
            // A buffered transcript write can be the question/approval itself.
            // Explicit cards settle through their response lifecycle, not mtime.
            guard explicitWaits[id] == nil else { continue }
            if let path = transcriptPaths[id], let mtime = Self.modificationDate(path) {
                lastActivity[id] = mtime
            }
        }
        let before = reducer.sessions
        // Reconciliation may discover an answer that happened before the
        // deadline even though this sweep runs later. Preserve its event time.
        for (id, answeredAt) in lastActivity.sorted(by: { $0.value < $1.value }) {
            if let session = before[id], session.status == .needsResponse,
               answeredAt > session.statusSince,
               answeredAt < session.statusSince.addingTimeInterval(MissedLedger.waitTimeout) {
                missedLedger.acknowledge(sessionID: id, now: answeredAt)
            }
        }
        evaluateMissed(now: now)
        reducer.reconcile(now: now, lastActivity: lastActivity, staleAfter: staleAfter)
        let removed = Set(before.keys).subtracting(reducer.sessions.keys)
        for id in removed {
            explicitWaits[id] = nil
            completionResults.removeSession(id)
            transcriptPaths[id] = nil
            cursorHookLog[id] = nil
            grokDirectories[id] = nil
            lastInteractionAt[id] = nil
        }
        attention.prune(keeping: Set(reducer.sessions.keys))
        for id in removed {
            guard let session = before[id] else { continue }
            appendJournal(
                sessionID: id, agent: session.agent, event: "sessionReconciled",
                source: .recovery, at: now
            )
        }
        evaluateMissed(now: now)
        if !removed.isEmpty { broadcast() }
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Called once per fresh transition into needsResponse (used for APNs push).
    public func setNeedsResponseHandler(_ handler: @escaping @Sendable (AgentSession) async -> Void) {
        needsResponseHandler = handler
    }

    /// True when a session with this id is currently tracked.
    public func hasSession(_ id: String) -> Bool {
        reducer.sessions[id] != nil
    }

    /// Parse a raw hook payload, apply it, enrich from the transcript, and push
    /// the new snapshot to every subscriber. Returns false if it wasn't a hook.
    /// `announcesWait: false` applies the event without firing the
    /// needs-response handler — for a wait the caller is about to announce
    /// itself (a `PermissionRequest` gate that opens an unknown session right
    /// before `beginApproval`), so one request never produces two pushes.
    @discardableResult
    public func ingest(_ data: Data, agent: AgentKind = .claudeCode, receivedAt: Date,
                       announcesWait: Bool = true) -> Bool {
        // Source-aware decode: the `?agent=` value tags Claude-shaped lifecycle
        // hooks directly and selects a translator only for different envelopes.
        switch HookDecoder.decode(data, agent: agent, receivedAt: receivedAt) {
        case let .event(event):
            if !appServerOutranks(event, from: .hook), !acpOutranks(event, from: .hook),
               let record = ToolLedger.hook(data, event: event) {
                toolLedger.observe(record, sessionID: event.sessionID, now: receivedAt, agent: event.agent)
            }
            ingest(event, observationSource: .hook, announcesWait: announcesWait)
            return true
        case .ignored:
            // Understood, but carries no progress (grok fires several such events
            // per session). The hook source is demonstrably alive and speaking a
            // shape we know, so record it as healthy rather than as an unknown
            // version — but claim no event-family coverage for it.
            recordSignal(agent: agent, source: .hook, at: receivedAt,
                         health: .healthy, coverage: nil)
            broadcast()
            return false
        case .undecodable:
            recordSignal(agent: agent, source: .hook, at: receivedAt,
                         health: .unknownVersion, coverage: nil)
            broadcast()
            return false
        }
    }

    /// Apply an already-normalized event from a local monitor such as the Codex
    /// Desktop rollout tailer. Hook payload parsing remains in the Data overload.
    /// Probe retirement passes `recordsEvidence: false` so a synthetic stop
    /// still migrates progress without minting rollout health evidence.
    public func ingest(_ event: HookEvent, recordsEvidence: Bool = true) {
        let inferredSource = event.observationSource ?? (event.agent == .codex ? .rollout : .hook)
        ingest(event, observationSource: inferredSource, recordsEvidence: recordsEvidence)
    }

    /// How recently the app-server daemon must have reported live progress for
    /// its evidence to outrank the rollout tailer and hooks on that thread.
    /// Idle discovery alone does not establish progress authority.
    public static let appServerAuthorityWindow: TimeInterval = 5 * 60

    /// Claude's status line: fills the session's name, effort, cost, context,
    /// PR and worktree. Only a session the hooks already opened is touched — a
    /// sample never creates one or moves its progress. Returns whether one was.
    @discardableResult
    public func applyStatusLine(_ sample: StatusLineSample, at date: Date) -> Bool {
        let applied = reducer.applyStatusLine(sample)
        rememberDirectory(sample.cwd, sessionID: sample.sessionID, at: date)
        if applied {
            if let path = sample.transcriptPath { transcriptPaths[sample.sessionID] = path }
            reducer.recordObservation(sessionID: sample.sessionID, source: .statusline,
                                      at: date, health: .healthy)
        }
        // The forwarder is demonstrably wired even when the session is unknown.
        recordSignal(agent: .claudeCode, source: .statusline, at: date, health: .healthy, coverage: nil)
        broadcast()
        return applied
    }

    /// Claude's background supervisor lends its job name and "needs" line to a
    /// session the hooks opened but never named. Read-only enrichment: a job
    /// never creates a row or moves its progress.
    public func applyBackgroundSessions(_ jobs: [ClaudeBackgroundSession]) {
        var changed = false
        for job in jobs where reducer.applyBackgroundSession(job) { changed = true }
        if changed { broadcast() }
    }

    /// Record a source's liveness without any session event — the app-server
    /// monitor's connection state, for the Settings diagnostics.
    public func recordSourceSignal(agent: AgentKind, source: ObservationSource,
                                   health: ObservationHealth, at date: Date) {
        recordSignal(agent: agent, source: source, at: date, health: health, coverage: nil)
        broadcast()
    }

    /// While the app-server daemon is reporting a Codex thread itself, a
    /// rollout or hook event for the same thread may only corroborate: it is
    /// recorded as evidence (and still enriches token facts) but does not move
    /// the three-state progress, so two sources never fight over one row.
    /// `sessionEnd` still passes — a CLI exit is a fact the daemon lacks.
    /// How recently Cursor's hooks must have reported a conversation for the
    /// transcript tailer to step aside on it. Cursor's hooks fire per tool call,
    /// so two minutes of silence means the hooks are not covering this turn (or
    /// are not installed) and the transcript is the live source after all.
    public static let cursorHookAuthorityWindow: TimeInterval = 2 * 60

    /// Cursor is described by two sources at once: its hooks — immediate, and the
    /// only thing that can be answered — and its agent transcript, a file
    /// flushed a beat later. While the hooks are live for a conversation the
    /// transcript may only corroborate; otherwise a line written just after the
    /// `stop` hook would flip a finished session back to `working` and mint a
    /// second completion for the same turn.
    private func cursorHooksOutrank(_ event: HookEvent, from source: ObservationSource) -> Bool {
        guard event.agent == .cursor, source == .transcript,
              let session = reducer.sessions[event.sessionID],
              let fresh = session.observations?.first(where: { $0.source == .hook }),
              fresh.health.isHealthy,
              event.timestamp.timeIntervalSince(fresh.lastObservedAt) < Self.cursorHookAuthorityWindow
        else { return false }
        return true
    }

    /// While the ACP host carries a conversation, the hooks its CLI still
    /// fires for it and the transcript it still writes describe the same turn
    /// a beat later; they may corroborate but must not move the three states
    /// or mint a second completion. `sessionEnd` passes: a process that has
    /// really gone is a fact the pipe reports by closing, not by an event.
    private func acpOutranks(_ event: HookEvent, from source: ObservationSource) -> Bool {
        (event.agent == .cursor || event.agent == .grok) && source != .acp && event.kind != .sessionEnd
            && acpHosted.contains(event.sessionID)
    }

    private func appServerOutranks(_ event: HookEvent, from source: ObservationSource) -> Bool {
        guard event.agent == .codex, source != .appserver, event.kind != .sessionEnd,
              let session = reducer.sessions[event.sessionID],
              let fresh = session.observations?.first(where: { $0.source == .appserver }),
              fresh.health.isHealthy,
              event.timestamp.timeIntervalSince(fresh.lastObservedAt) < Self.appServerAuthorityWindow
        else { return false }
        // An idle loaded thread still disproves an ownerless retirement probe.
        if event.probeRetirement { return true }
        guard let progressAt = appServerProgressAt[event.sessionID] else { return false }
        return event.timestamp.timeIntervalSince(progressAt) < Self.appServerAuthorityWindow
    }

    private func ingest(
        _ event: HookEvent,
        observationSource: ObservationSource,
        recordsEvidence: Bool = true,
        announcesWait: Bool = true
    ) {
        if dropsCursorObserveOnly(event) { return }
        // Corroborating progress can arrive after the exact native turn ended.
        // Keep its observation, but never reopen that turn or clear its result.
        let completedTurnProgress = completionResults.isCompletedProgress(event, sourceID: sourceID)
        if event.agent == .codex, !completedTurnProgress {
            if observationSource == .rollout, recordsEvidence,
               [.userPromptSubmit, .preToolUse, .postToolUse, .notification].contains(event.kind) {
                activeCodexRollouts.insert(event.sessionID)
            } else if observationSource != .hook, event.kind == .stop || event.kind == .sessionEnd {
                activeCodexRollouts.remove(event.sessionID)
            }
        }
        let prematureCodexStop = event.agent == .codex && observationSource == .hook
            && event.kind == .stop && activeCodexRollouts.contains(event.sessionID)
        if event.agent == .codex, !completedTurnProgress {
            if event.kind == .sessionEnd { appServerProgressAt[event.sessionID] = nil }
            else if observationSource == .appserver, recordsEvidence {
                switch event.kind {
                case .userPromptSubmit, .preToolUse, .postToolUse, .notification, .stop:
                    appServerProgressAt[event.sessionID] = event.timestamp
                case .sessionStart, .sessionMetadataChanged, .childLifecycle, .sessionEnd:
                    break
                }
            }
        }
        recordCursorHookLog(event, from: observationSource)
        // A corroborating source may supply the menu's read-only round evidence.
        if let path = event.transcriptPath { transcriptPaths[event.sessionID] = path }
        if completedTurnProgress || prematureCodexStop || appServerOutranks(event, from: observationSource)
            || acpOutranks(event, from: observationSource)
            || cursorHooksOutrank(event, from: observationSource) {
            if reducer.sessions[event.sessionID] != nil, let name = event.sessionName {
                reducer.apply(.init(kind: .sessionMetadataChanged, sessionID: event.sessionID,
                    agent: event.agent, sessionName: name, timestamp: event.timestamp),
                    observationSource: observationSource, recordsEvidence: false)
            }
            // ACP owns the prompt identity and final text. Native hooks carry
            // another prompt ID and must not replace that completion mapping.
            if !completedTurnProgress, !acpOutranks(event, from: observationSource) {
                completionResults.observe(event, session: reducer.sessions[event.sessionID],
                    sourceID: sourceID, now: Date(), authoritative: false)
                persistCompletionResults()
            }
            if let enrichment = event.enrichment {
                enrichSession(sessionID: event.sessionID, with: enrichment)
            }
            if recordsEvidence {
                reducer.recordObservation(sessionID: event.sessionID, source: observationSource,
                                          at: event.timestamp, health: .healthy)
                recordSignal(agent: event.agent, source: observationSource, at: event.timestamp,
                             health: .healthy, coverage: Self.coverage(for: event.kind))
            }
            broadcast()
            return
        }
        if observationSource != .hook, event.childID == nil,
           event.kind == .preToolUse || event.kind == .postToolUse {
            let record = event.toolCall ?? ToolCallRecord(id: UUID().uuidString, tool: event.toolName ?? "Tool",
                observedAt: event.timestamp, source: observationSource.rawValue,
                coverage: "Tool activity observed; call identity and result details unavailable")
            toolLedger.observe(record, sessionID: event.sessionID, now: event.timestamp, agent: event.agent)
        }
        let wasWaiting = reducer.sessions[event.sessionID]?.status == .needsResponse
        rememberDirectory(event.cwd, sessionID: event.sessionID, at: event.timestamp)
        if let cwd = event.cwd, cwd.hasPrefix("/") { workingDirectories[event.sessionID] = cwd }
        let previousCompletionID = reducer.sessions[event.sessionID]?.completionID
        reducer.apply(event, observationSource: observationSource, recordsEvidence: recordsEvidence)
        if let wait = explicitWaits[event.sessionID],
           reducer.sessions[event.sessionID].map(wait.matches) != true {
            explicitWaits[event.sessionID] = nil
        }
        completionResults.observe(event, session: reducer.sessions[event.sessionID], sourceID: sourceID, now: Date(),
            createdCompletion: reducer.sessions[event.sessionID]?.completionID != previousCompletionID)
        persistCompletionResults()
        // A prompt is the user driving the session in person.
        if event.kind == .userPromptSubmit { lastInteractionAt[event.sessionID] = event.timestamp }
        if let enrichment = event.enrichment {
            enrichSession(sessionID: event.sessionID, with: enrichment)
        }
        if recordsEvidence {
            recordSignal(agent: event.agent, source: observationSource, at: event.timestamp,
                         health: .healthy, coverage: Self.coverage(for: event.kind))
        }
        if reducer.sessions[event.sessionID] == nil {
            activeCodexRollouts.remove(event.sessionID)
            cursorFollowupHandedAt[event.sessionID] = nil
            // Session was removed (e.g. SessionEnd) — forget its side data.
            transcriptPaths[event.sessionID] = nil
            cursorHookLog[event.sessionID] = nil
            pendingTerminalRefs[event.sessionID] = nil
            grokDirectories[event.sessionID] = nil
            lastInteractionAt[event.sessionID] = nil
            attention.set(nil, for: event.sessionID)
        } else {
            // Grok keeps a session's facts in a directory of files rather than
            // one transcript, so it enriches from that directory instead.
            if event.agent == .grok {
                enrichFromGrokSession(event)
            } else if let path = event.transcriptPath {
                let transcriptHealth = Self.sourceHealth(at: path)
                reducer.recordObservation(sessionID: event.sessionID, source: .transcript,
                                          at: event.timestamp, health: transcriptHealth)
                recordSignal(agent: event.agent, source: .transcript, at: event.timestamp,
                             health: transcriptHealth, coverage: .turn)
                if var info = TranscriptReader.read(path: path) {
                    // Stop can arrive before its assistant line reaches disk.
                    // This unscoped metadata tail must not replace the ending's
                    // own summary with an earlier round. Exact completion proof
                    // may still enrich the recap later through completionText.
                    if event.kind == .stop { info.summary = nil }
                    enrichSession(sessionID: event.sessionID, with: info)
                }
            }
            // Apply a terminal ref that arrived before this session existed.
            if let ref = pendingTerminalRefs[event.sessionID] {
                reducer.setTerminalRef(sessionID: event.sessionID, ref)
            }
        }
        appendJournal(
            sessionID: event.sessionID,
            agent: event.agent,
            event: event.kind.rawValue,
            source: observationSource,
            at: event.timestamp
        )
        evaluateMissed(now: event.timestamp)
        broadcast()
        if announcesWait, !wasWaiting, let session = reducer.sessions[event.sessionID],
           session.status == .needsResponse, let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    /// An Ask or Edit chat in Cursor (`composer_mode` on `sessionStart`,
    /// cursor.com/docs/hooks) never becomes a row: its `sessionStart` enrols the
    /// id and is dropped, every later event for that id is dropped, and its
    /// `sessionEnd` releases the id and is dropped too. Nothing is reduced,
    /// recorded as evidence or broadcast, so the chat cannot enter the three
    /// states or ring a cue. Keyed on the conversation id, so the transcript
    /// tailer's events for the same chat are held back as well.
    private func dropsCursorObserveOnly(_ event: HookEvent) -> Bool {
        guard event.agent == .cursor else { return false }
        if event.kind == .sessionStart, event.observeOnly {
            cursorObserveOnly.insert(event.sessionID)
            cursorHookLog[event.sessionID] = nil
            return true
        }
        guard cursorObserveOnly.contains(event.sessionID) else { return false }
        if event.kind == .sessionEnd { cursorObserveOnly.remove(event.sessionID) }
        return true
    }

    /// Append what a Cursor hook said to the conversation's hook log: the
    /// prompt, the agent's reply, a "⚙ tool" marker for each tool it reaches
    /// for, and the tool's result when the hook carried one. Only the hook
    /// source writes here — the transcript has its own reader.
    private func recordCursorHookLog(_ event: HookEvent, from source: ObservationSource) {
        guard event.agent == .cursor, source == .hook else { return }
        let entry: TranscriptEntry?
        switch event.kind {
        case .userPromptSubmit:
            entry = event.message.map { TranscriptEntry(role: "user", text: $0) }
        case .sessionMetadataChanged:
            entry = event.message.map { TranscriptEntry(role: "assistant", text: $0) }
        case .preToolUse:
            // Thinking blocks are activity, not dialogue: one per model
            // generation would drown the prompts and results this log is for.
            entry = event.toolName.flatMap { $0 == "Thinking" ? nil : TranscriptEntry(role: "assistant", text: "⚙ \($0)") }
        case .postToolUse:
            entry = event.toolOutput.map { TranscriptEntry(role: "assistant", text: $0) }
        case .sessionEnd:
            cursorHookLog[event.sessionID] = nil
            return
        default:
            entry = nil
        }
        guard let entry else { return }
        var log = cursorHookLog[event.sessionID] ?? []
        log.append(entry)
        if log.count > Self.cursorHookLogLimit {
            log.removeFirst(log.count - Self.cursorHookLogLimit)
        }
        cursorHookLog[event.sessionID] = log
    }

    /// Whether Cursor's hooks reported this conversation within
    /// `cursorHookAuthorityWindow` — the same freshness that lets a hook
    /// outrank the transcript on progress (`cursorHooksOutrank`).
    private func hasFreshCursorHookEvidence(sessionID: String, now: Date) -> Bool {
        guard let session = reducer.sessions[sessionID],
              let evidence = session.observations?.first(where: { $0.source == .hook }),
              evidence.health.isHealthy else { return false }
        return now.timeIntervalSince(evidence.lastObservedAt) < Self.cursorHookAuthorityWindow
    }

    /// Wait at most until two seconds after the original ending. Results are
    /// memory-only and must be revalidated again by the eventual notification owner.
    public func workspaceChanges(sessionID: String, scope: ChangesScope, baseline: String?, file: String?) async -> WorkspaceChanges {
        let session = reducer.sessions[sessionID]
        let cwd = workingDirectories[sessionID] ?? session?.terminalRef?.cwd ?? session?.worktree
        let shared = cwd.map { path in workingDirectories.values.filter { $0 == path }.count > 1 } ?? false
        return await Task.detached(priority: .utility) {
            WorkspaceChangesReader.read(cwd: cwd, scope: scope, baseline: baseline, file: file, shared: shared)
        }.value
    }

    private func resultKey(sessionID: String, completionID: String) -> String? {
        sourceID.map { RecapEntry.completedID(sourceID: $0, sessionID: sessionID, completionID: completionID) }
    }

    private func persistCompletionResults() {
        for id in completionResults.retain(in: &recapLedger, now: Date()) {
            recapPresentations[id] = nil
            if var notice = noticeLedger?.notices[id], notice.state == .pending || notice.state == .summary {
                notice.state = .cancelled; notice.text = nil
                _ = noticeLedger?.save(notice)
                noticeTasks.removeValue(forKey: id)?.cancel()
            }
        }
    }

    private func resultRejected(sessionID: String, completionID: String) -> Bool {
        completionResults.isRejected(sessionID: sessionID, completionID: completionID, sourceID: sourceID)
    }

    private func completionIsCurrent(sessionID: String, completionID: String) -> Bool {
        completionResults.isCurrent(session: reducer.sessions[sessionID], completionID: completionID, sourceID: sourceID)
    }

    /// Exact historical reads enrich only this persisted key. They do not
    /// restore a notification candidate, emit progress, or acknowledge reading.
    private func readCompletionRecord(key: String) async -> FrozenCompletionResult? {
        let request: CompletionResults.ReadRequest
        switch completionResults.readPlan(key: key, sourceID: sourceID, now: Date()) {
        case .ready(let result): return result
        case .unavailable: return nil
        case .read(let pending): request = pending
        }
        let evidence = await Task.detached { request.readEvidence() }.value
        guard !Task.isCancelled,
              completionResults.merge(evidence, for: request, sourceID: sourceID, now: Date()) else { return nil }
        persistCompletionResults()
        return completionResults.retainedResult(key: key, now: Date())
    }

    public func completionBody(sessionID: String, completionID: String) async -> CompletionBody {
        switch completionResults.bodyRead(sessionID: sessionID, completionID: completionID,
                                          session: reducer.sessions[sessionID], sourceID: sourceID) {
        case .refused(let body): return body
        case .read(let key):
            let result = await readCompletionRecord(key: key)
            return completionResults.body(sessionID: sessionID, completionID: completionID,
                session: reducer.sessions[sessionID], sourceID: sourceID, result: result, now: Date())
        }
    }

    public func completionResult(sessionID: String, completionID: String, forReading: Bool = false) async -> CompletionResultAvailability {
        guard completionIsCurrent(sessionID: sessionID, completionID: completionID), !Task.isCancelled else { return .cancelled }
        guard let key = resultKey(sessionID: sessionID, completionID: completionID) else { return .resultUnavailable }
        if forReading {
            let result = await readCompletionRecord(key: key)
            guard completionIsCurrent(sessionID: sessionID, completionID: completionID), !Task.isCancelled else { return .cancelled }
            return result.map(CompletionResultAvailability.ready) ?? .resultUnavailable
        }
        var waited = false
        while true {
            guard completionIsCurrent(sessionID: sessionID, completionID: completionID),
                  reducer.sessions[sessionID]?.hasUnreadCompletion == true, !Task.isCancelled else { return .cancelled }
            let deadline: Date
            let needsRead: Bool
            switch completionResults.notificationState(sessionID: sessionID, completionID: completionID, sourceID: sourceID) {
            case .finished(let outcome): return outcome
            case .waiting(let until, let pendingRead): deadline = until; needsRead = pendingRead
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return waited ? .resultUnavailable : .expired }
            if needsRead, completionReads.insert(completionID).inserted {
                Task {
                    _ = await self.readCompletionRecord(key: key)
                    self.completionReads.remove(completionID)
                }
            }
            do { try await Task.sleep(for: .seconds(min(0.05, remaining))); waited = true }
            catch { return .cancelled }
        }
    }

    /// Layer a Grok session directory's facts onto the session, and fold the
    /// subagents the parent recorded into the same child topology the hook path
    /// builds. The directory is the only source that names the children a
    /// parent owns: `subagent_stop` fires inside the child's own session.
    private func enrichFromGrokSession(_ event: HookEvent) {
        guard let directory = grokSessionDirectory(for: event) else { return }
        let health = Self.sourceHealth(
            at: directory.appendingPathComponent("updates.jsonl").path)
        reducer.recordObservation(sessionID: event.sessionID, source: .transcript,
                                  at: event.timestamp, health: health)
        recordSignal(agent: .grok, source: .transcript, at: event.timestamp,
                     health: health, coverage: .turn)
        guard let snapshot = GrokSessionReader.read(directory: directory) else { return }
        enrichSession(sessionID: event.sessionID, with: snapshot.info)

        // The hook path is authoritative on a child's *state*: `SubagentStop`
        // fires before the child's teardown rewrites `meta.json`, so the
        // directory still says "running" for a child we already know finished.
        // The directory may therefore only introduce children the hooks missed,
        // and stop children — never move one back to running.
        let known = Set(reducer.sessions[event.sessionID]?.childAgents?.map(\.id) ?? [])
        for child in snapshot.subagents {
            let childID = "subagent:\(child.id)"       // same identity GrokParser mints
            guard child.finished || !known.contains(childID) else { continue }
            // Stamped with the observing event, not the child's own start time:
            // the reducer drops child updates older than what it already holds,
            // and a long-finished subagent must not rewind the parent's clock.
            reducer.apply(HookEvent(
                kind: .childLifecycle,
                sessionID: event.sessionID,
                agent: .grok,
                message: child.detail,
                observationSource: .transcript,
                timestamp: event.timestamp,
                childID: childID,
                childKind: .subagent,
                childName: child.type,
                childType: child.type,
                childAction: child.finished ? .stopped : .started
            ), observationSource: .transcript)
        }
    }

    /// The session directory for a Grok event: the parent of the hook's
    /// `transcriptPath` (it names `updates.jsonl`) when there is one, else the
    /// locator over the session's cwd. Cached once resolved.
    private func grokSessionDirectory(for event: HookEvent) -> URL? {
        if let cached = grokDirectories[event.sessionID] { return cached }
        let resolved = event.transcriptPath.flatMap(GrokSessionLocator.directory(forTranscriptPath:))
            ?? GrokSessionLocator.locate(sessionID: event.sessionID, cwd: event.cwd,
                                         grokHome: grokHome)
        guard let resolved else { return nil }
        grokDirectories[event.sessionID] = resolved
        // `sweep` measures "did the session advance" from this path's mtime.
        transcriptPaths[event.sessionID] = resolved
            .appendingPathComponent("updates.jsonl").path
        return resolved
    }

    private func enrichSession(sessionID: String, with info: TranscriptInfo) {
        var metadata = info
        if let wait = explicitWaits[sessionID],
           reducer.sessions[sessionID].map(wait.matches) == true {
            metadata.pendingQuestion = nil
            metadata.pendingPermissionTool = nil
        }
        reducer.enrich(sessionID: sessionID, with: metadata)
    }

    public func beginApproval(sessionID: String, _ approval: PendingApproval, at: Date, source: ObservationSource = .hook) {
        guard !Task.isCancelled else { return }
        reducer.setPendingApproval(sessionID: sessionID, approval, at: at)
        if let session = reducer.sessions[sessionID] {
            explicitWaits[sessionID] = .approval(approval.id)
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "approvalRequested", source: source, at: at)
        }
        evaluateMissed(now: at)
        broadcast()
        if let session = reducer.sessions[sessionID], let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    public func endApproval(sessionID: String, approvalID: String, at: Date, source: ObservationSource = .hook) {
        guard reducer.sessions[sessionID]?.pendingApproval?.id == approvalID else { return }
        if case .approval = explicitWaits[sessionID] { explicitWaits[sessionID] = nil }
        cancelMissedWait(sessionID: sessionID, now: at)
        reducer.clearPendingApproval(sessionID: sessionID, at: at)
        if let session = reducer.sessions[sessionID] {
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "approvalResolved", source: source, at: at)
        }
        broadcast()
    }

    public func beginQuestion(sessionID: String, _ question: PendingQuestion, at: Date, source: ObservationSource = .hook) {
        guard !Task.isCancelled else { return }
        reducer.setPendingQuestion(sessionID: sessionID, question, at: at)
        if let session = reducer.sessions[sessionID] {
            explicitWaits[sessionID] = .question(question.id)
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "questionAsked", source: source, at: at)
        }
        evaluateMissed(now: at)
        broadcast()
        if let session = reducer.sessions[sessionID], let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    /// Whether the app-server daemon reported this Codex session recently
    /// enough to be carrying its approvals itself (the hook gate then steps
    /// aside instead of raising a second card for the same request).
    public func hasFreshAppServerEvidence(sessionID: String, now: Date) -> Bool {
        guard let session = reducer.sessions[sessionID],
              let evidence = session.observations?.first(where: { $0.source == .appserver }),
              evidence.health.isHealthy else { return false }
        return now.timeIntervalSince(evidence.lastObservedAt) < Self.appServerAuthorityWindow
    }

    public func makeQuestionReadOnly(sessionID: String, questionID: String) {
        // The native UI still owns an unanswered prompt. Keep explicitWaits:
        // a buffered write of the question itself is not evidence of an answer.
        reducer.makeQuestionReadOnly(sessionID: sessionID, questionID: questionID)
        broadcast()
    }

    public func endQuestion(sessionID: String, questionID: String, at: Date, source: ObservationSource = .hook) {
        guard reducer.sessions[sessionID]?.pendingQuestion?.id == questionID else { return }
        if case .question = explicitWaits[sessionID] { explicitWaits[sessionID] = nil }
        cancelMissedWait(sessionID: sessionID, now: at)
        reducer.clearPendingQuestion(sessionID: sessionID, at: at)
        if let session = reducer.sessions[sessionID] {
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "questionResolved", source: source, at: at)
        }
        broadcast()
    }

    public func setTerminalRef(sessionID: String, _ ref: TerminalRef) {
        // Remembered even if the session isn't here yet — and merged for the
        // same reason the reducer merges: a re-capture that skipped the Ghostty
        // probe must not erase the id the first one found.
        pendingTerminalRefs[sessionID] = pendingTerminalRefs[sessionID]?.merging(ref) ?? ref
        if reducer.sessions[sessionID] != nil {
            reducer.setTerminalRef(sessionID: sessionID, ref)
            broadcast()
        }
    }

    public func terminalRef(for sessionID: String) -> TerminalRef? {
        reducer.sessions[sessionID]?.terminalRef
    }

    /// The Codex Desktop thread a session is, when it is one. The rollout tailer
    /// is the only writer, through the events it already sends.
    public func desktopThreadID(for sessionID: String) -> String? {
        reducer.sessions[sessionID]?.desktopThreadID
    }

    /// Authoritative read acknowledgement. Snapshot delivery and passive list
    /// visibility never call this; only explicit selection/open/jump actions do.
    public func acknowledgeCompletion(_ request: CompletionReadRequest, now: Date = Date()) -> CompletionReadResponse {
        guard let sourceID, request.sourceID == sourceID else {
            return CompletionReadResponse(outcome: .sourceMismatch)
        }
        guard let session = reducer.sessions[request.sessionID] else {
            return CompletionReadResponse(outcome: .unavailable)
        }
        guard session.status == .done, session.completionID == request.completionID,
              !request.completionID.isEmpty else {
            return CompletionReadResponse(outcome: .staleCompletion)
        }
        let unread = request.markUnread == true
        guard session.hasUnreadCompletion != unread else {
            return CompletionReadResponse(outcome: .alreadyAcknowledged)
        }
        let previousReducer = reducer
        let previousJournal = lifecycleJournal
        if unread {
            _ = reducer.markCompletionUnread(sessionID: request.sessionID, completionID: request.completionID)
        } else {
            guard reducer.acknowledgeCompletion(sessionID: request.sessionID, completionID: request.completionID) else {
                return CompletionReadResponse(outcome: .staleCompletion)
            }
        }
        guard appendJournal(sessionID: request.sessionID, agent: session.agent,
                            event: unread ? "completionMarkedUnread" : "completionAcknowledged", source: .recovery, at: now) else {
            reducer = previousReducer
            lifecycleJournal = previousJournal
            return CompletionReadResponse(outcome: .failed)
        }
        broadcast()
        return CompletionReadResponse(outcome: .accepted)
    }

    /// Marks this exact wait viewed without resolving its approval/question.
    @discardableResult
    public func acknowledgeWait(_ request: WaitReadRequest, now: Date = Date()) -> Bool {
        guard sourceID == request.sourceID, !request.sourceID.isEmpty,
              let session = reducer.sessions[request.sessionID],
              session.status == .needsResponse,
              WaitReadRequest(sourceID: request.sourceID, session: session) == request else { return false }
        cancelMissedWait(sessionID: request.sessionID, now: now)
        return true
    }

    /// Mark all from a recap: move the recap horizon forward to the newest
    /// entry the user saw. The horizon only advances, so a retried or reordered
    /// request is harmless; it changes no round's read state and writes no
    /// lifecycle event — reading a round stays an exact-round `/acknowledge`.
    public func advanceRecapHorizon(_ request: RecapReadRequest, now: Date = Date()) -> RecapReadOutcome {
        guard let sourceID, !sourceID.isEmpty, request.sourceID == sourceID else { return .sourceMismatch }
        do {
            if try recapLedger.advanceHorizon(to: request.horizon, now: now) { broadcast() }
            return .accepted
        } catch {
            return .failed
        }
    }

    /// Record any wait that has sat in `needsResponse` for five minutes
    /// without an acknowledgement. Safe to call on every poll.
    public func evaluateMissed(now: Date) {
        missedLedger.observe(Array(reducer.sessions.values), now: now)
    }

    /// This week's miss counts (Monday 06:00 local). Evaluates outstanding
    /// waits first so a Settings refresh is current.
    public func missedCounts(week: Date = Date(), now: Date = Date(),
                             calendar: Calendar = .current) -> MissedCounts {
        evaluateMissed(now: now)
        return missedLedger.counts(weekContaining: week, now: now, calendar: calendar)
    }

    private func cancelMissedWait(sessionID: String, now: Date) {
        evaluateMissed(now: now)
        missedLedger.acknowledge(sessionID: sessionID, now: now)
    }

    public func snapshot(now: Date) -> Snapshot {
        currentSnapshot(now: now)
    }

    /// Replace the current account allowance. It is composed into every snapshot
    /// but never reaches the reducer: quota is account state, not session
    /// progress, and a provider outage must not move a single session.
    /// A change broadcasts, so the phone and the wrist see it without waiting
    /// for the next session event.
    public func setProviderQuota(_ quota: [ProviderQuota]) {
        guard quota != providerQuota else { return }
        providerQuota = quota
        broadcast()
    }

    /// Replace the current token-consumption summary. Composed into every
    /// snapshot beside quota; never reaches the reducer.
    public func setTokenConsumption(_ snapshot: TokenConsumptionSnapshot?) {
        guard snapshot != tokenConsumption else { return }
        tokenConsumption = snapshot
        broadcast()
    }

    /// Replace the Cursor model list the phone may choose from. Account
    /// state like quota: composed into every snapshot, never near the reducer,
    /// broadcast on change so a fresh sign-in reaches the sheet.
    public func setCursorModels(_ models: [String]) {
        guard models != cursorModels else { return }
        cursorModels = models
        broadcast()
    }

    /// Replace the agent list the New task sheet may choose from; composed
    /// into every snapshot like the Cursor models, broadcast on change.
    public func setDispatchAgents(_ agents: [AgentKind]) {
        guard agents != dispatchAgents else { return }
        dispatchAgents = agents
        broadcast()
    }

    /// The one place a runtime snapshot is assembled: sessions and diagnostics
    /// from the reducer, allowance from beside it.
    func refreshCodexNames(index: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/session_index.jsonl")) {
        codexThreadNames.refresh(index: index)
        for session in reducer.sessions.values where session.agent == .codex {
            guard let name = codexThreadNames.values[session.id], name != session.name else { continue }
            reducer.apply(.init(kind: .sessionMetadataChanged, sessionID: session.id,
                agent: .codex, sessionName: name, timestamp: session.updatedAt),
                observationSource: .rollout, recordsEvidence: false)
        }
    }

    private func currentSnapshot(now: Date) -> Snapshot {
        refreshCodexNames()
        var snapshot = reducer.snapshot(now: now, observationDiagnostics: diagnostics(now: now))
        snapshot.sessions += copilotHistory.values.map(\.session).sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        snapshot.sessions += cursorHistorySessions().sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
        snapshot.sessions += cursorCloudHistorySessions()
        if copilotReadFailed || !copilotHistory.isEmpty {
            var diagnostics = snapshot.observationDiagnostics ?? []
            diagnostics.removeAll { $0.agent == .copilot }
            diagnostics.append(.init(agent: .copilot, sources: [.init(source: .transcript,
                health: copilotReadFailed ? .sourceUnreadable : .healthy,
                reasonCode: copilotReadFailed ? "copilotHistoryUnreadable" : "copilotHistoryOnly")]))
            snapshot.observationDiagnostics = diagnostics
        }
        toolLedger.prune(now: now)
        snapshot.sessions = snapshot.sessions.map { toolLedger.applying(to: $0) }
        snapshot.sourceID = sourceID
        snapshot.providerQuota = providerQuota.isEmpty ? nil : providerQuota
        snapshot.tokenConsumption = tokenConsumption
        let directories = recentDirectories(now: now)
        snapshot.recentDirectories = directories.isEmpty ? nil : directories
        // Handoff documents under those checkouts (ADR-0023). The file is the
        // record; `takenBy` is what this process started from each one.
        let handoffs = handoffScanner.scan(directories: directories).map { record in
            var record = record
            record.takenBy = continuationLedger.takenBy(handoffPath: record.path)
            return record
        }
        snapshot.handoffs = handoffs.isEmpty ? nil : handoffs
        if !continuationLedger.records.isEmpty {
            snapshot.sessions = snapshot.sessions.map { session in
                guard let key = ContinueWith.sessionKey(for: session),
                      let source = continuationLedger.sourceKey(forReceiver: key) else { return session }
                var session = session
                session.continuesSessionKey = source
                return session
            }
        }
        let visibleIDs = Set(snapshot.sessions.map(\.id))
        snapshot.sessions += acpRecoveryRows.values.filter { !visibleIDs.contains($0.id) }
        snapshot.cursorModels = cursorModels.isEmpty ? nil : cursorModels
        snapshot.dispatchAgents = dispatchAgents.isEmpty ? nil : dispatchAgents
        snapshot.sessions = snapshot.sessions.map { session in
            var session = session
            session.attentionOverride = attention[session.id]
            session.attention = attention[session.id]
                ?? AutoAttention.level(lastInteractionAt: lastInteractionAt[session.id], now: now)
            session.completionNotice = completionNotice(for: session, now: now)
            session.completionText = completionResults.snapshotText(for: session, sourceID: sourceID)
            session.controlChannel = controlChannel(for: session, now: now)
            if let recovery = acpRecoveryRows[session.id], !acpHosted.contains(session.id) {
                session.historyOnly = true
                session.cursorACPRecoverable = true
                session.cursorACPRecoveryUnavailable = recovery.cursorACPRecoveryUnavailable
                session.cursorACPRecoveryFailure = recovery.cursorACPRecoveryFailure
                session.status = .done
                session.pendingApproval = nil
                session.pendingQuestion = nil
                session.waitKind = nil
            }
            return session
        }
        // Ended rounds are recorded from the assembled sessions — after tool
        // evidence and attention are layered on — so every observation path
        // records the same facts, and the recap reads mute and acknowledgement
        // from the very list the other surfaces show.
        let recapResults = completionResults.recapResults(for: snapshot.sessions, sourceID: sourceID)
        recapLedger.observe(snapshot.sessions, sourceID: sourceID, now: now, results: recapResults)
        recapCaptureAttempts.formIntersection(recapLedger.entries.keys)
        for entry in completionResults.recapRecovery(in: recapLedger, now: now) {
            guard recapCaptureAttempts.insert(entry.id).inserted else { continue }
            recapCaptureTasks[entry.id] = Task {
                await self.captureRecapResult(id: entry.id, sessionID: entry.sessionID, completionID: entry.completionID)
                self.recapCaptureTasks.removeValue(forKey: entry.id)
            }
        }
        snapshot.recap = recapLedger.recap(now: now, sessions: snapshot.sessions) { [noticeLedger] id in
            guard let notice = noticeLedger?.notices[id], notice.state == .summary,
                  let text = notice.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, text.count <= 180 else { return nil }
            return text
        }
        let presentationRevision = presentationConfiguration().presentationRevision
        snapshot.contentPresentationRevision = presentationRevision
        if var recap = snapshot.recap {
            recap.entries = recap.entries.map { entry in
                var entry = entry
                if recapLedger.entries[entry.id]?.resultConflict != true,
                   entry.completionID.map({ !resultRejected(sessionID: entry.sessionID, completionID: $0) }) ?? true,
                   let content = recapPresentations[entry.id], content.revision == presentationRevision {
                    entry.contentPresentation = content
                }
                return entry
            }
            snapshot.recap = recap
        }
        let active = Set(snapshot.sessions.compactMap { $0.completionNotice?.id })
        for id in noticeTasks.keys where !active.contains(id) {
            noticeTasks.removeValue(forKey: id)?.cancel()
            if var notice = noticeLedger?.notices[id], notice.state == .pending {
                notice.state = .cancelled
                _ = noticeLedger?.save(notice)
            }
        }
        return snapshot
    }

    /// Directories sessions have run in, newest first (bounded). A phone may
    /// only start a task in one of these.
    public func recentDirectories(now: Date = Date()) -> [String] { recentDirectoryLedger.recent(now: now) }

    public func isKnownDirectory(_ path: String, now: Date = Date()) -> Bool { recentDirectoryLedger.isKnown(path, now: now) }

    /// Only a current scanned document naming this source may accompany dispatch.
    /// Both the HTTP and Mac entry points validate before any launcher starts.
    public func acceptsContinuation(_ continuation: DispatchContinuation?, now: Date = Date()) -> Bool {
        guard let continuation else { return true }
        guard let source = try? HistorySessionReference(continuation.sourceKey), source.key == continuation.sourceKey else { return false }
        guard let path = continuation.handoffPath else { return true }
        guard path.hasPrefix("/") else { return false }
        let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return handoffScanner.scan(directories: recentDirectories(now: now)).contains {
            $0.sourceKey == source.key && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == canonical
        }
    }

    private func rememberDirectory(_ cwd: String?, sessionID: String?, at date: Date) {
        recentDirectoryLedger.remember(cwd, sessionID: sessionID, at: date)
    }

    /// The terminal program the user's most recent terminal-backed session
    /// runs in — where a new window should open.
    public func preferredTerminalProgram() -> String? {
        reducer.sessions.values
            .filter { $0.terminalRef?.termProgram != nil }
            .max { $0.updatedAt < $1.updatedAt }?
            .terminalRef?.termProgram
    }

    /// The session's recent output (user prompts + assistant prose / tool activity)
    /// for the detail pane. Empty when the session has no known transcript, so
    /// the UI can show a graceful "no transcript" state.
    public func recentTranscript(sessionID: String, limit: Int = 12) -> [TranscriptEntry] {
        let output = recentOutput(sessionID: sessionID, limit: limit)
        return output.entries.map { TranscriptEntry(role: $0.role, text: $0.text) }
    }

    /// Authenticated recent-output payload for the phone. Read-only: does not
    /// acknowledge completions or otherwise move Session state.
    public func recentOutput(
        sessionID: String,
        limit: Int = 12,
        perEntryLimit: Int = 600,
        rolloutPath: String? = nil,
        appServerItems: [[String: Any]]? = nil
    ) -> RecentOutput {
        if let record = copilotHistory[sessionID] {
            if copilotReadFailed {
                return .unavailable(sessionId: sessionID, reason: .unreadable,
                    source: .transcript, updatedAt: record.output.updatedAt)
            }
            let entries = record.output.entries.suffix(max(0, min(limit, 12)))
            let clipped = entries.map { RecentOutputEntry(role: $0.role,
                text: String($0.text.prefix(max(0, min(perEntryLimit, 600))))) }
            return RecentOutput(sessionId: sessionID, source: .transcript,
                updatedAt: record.output.updatedAt,
                truncated: record.output.truncated || entries.count < record.output.entries.count
                    || zip(entries, clipped).contains { $0.text != $1.text }, entries: clipped)
        }
        guard let session = reducer.sessions[sessionID] else {
            return .unavailable(sessionId: sessionID, reason: .unknownSession)
        }
        if let directory = grokDirectories[sessionID] {
            let path = directory.appendingPathComponent("updates.jsonl").path
            guard let data = Self.readTail(path: path, maxBytes: GrokSessionReader.updatesTailBytes) else {
                return .unavailable(sessionId: sessionID, reason: .unreadable, source: .transcript)
            }
            return finish(
                sessionID: sessionID, source: .transcript, path: path,
                RecentOutputReader.grok(updatesTail: data, limit: limit, perEntryLimit: perEntryLimit))
        }
        if session.agent == .codex, let items = appServerItems, !items.isEmpty {
            return finish(
                sessionID: sessionID, source: .appserver, path: nil,
                RecentOutputReader.codexAppServer(
                    items: items, limit: limit, perEntryLimit: perEntryLimit))
        }
        // Cursor has two dialogue sources and one rule for choosing between
        // them: the hooks are the live source while their evidence is fresh
        // within `cursorHookAuthorityWindow`, the transcript otherwise. It is
        // the same window that decides which source drives progress
        // (`cursorHooksOutrank`), so the pane and the row never disagree about
        // who is speaking for the session. The hook log is also the only place
        // tool *results* exist — the agent transcript records none.
        if session.agent == .cursor,
           let log = cursorHookLog[sessionID], !log.isEmpty,
           hasFreshCursorHookEvidence(sessionID: sessionID, now: Date()) {
            let bounded = RecentOutputReader.bound(log, limit: limit, perEntryLimit: perEntryLimit)
            return RecentOutput(
                sessionId: sessionID, source: .hook,
                updatedAt: session.observations?.first(where: { $0.source == .hook })?.lastObservedAt,
                truncated: bounded.truncated,
                entries: bounded.entries.map { RecentOutputEntry(role: $0.role, text: $0.text) })
        }
        let path = rolloutPath ?? transcriptPaths[sessionID]
        guard let path else {
            return .unavailable(sessionId: sessionID, reason: .noSource)
        }
        let source: ObservationSource = session.agent == .codex ? .rollout : .transcript
        guard let data = Self.readTail(path: path, maxBytes: 262_144) else {
            return .unavailable(sessionId: sessionID, reason: .unreadable, source: source)
        }
        let slice: RecentOutputSlice
        switch session.agent {
        case .codex:
            let rollout = RecentOutputReader.codexRollout(
                tail: data, limit: limit, perEntryLimit: perEntryLimit)
            slice = rollout.entries.isEmpty
                ? RecentOutputReader.claude(tail: data, limit: limit, perEntryLimit: perEntryLimit)
                : rollout
        case .claudeCode:
            slice = RecentOutputReader.claude(tail: data, limit: limit, perEntryLimit: perEntryLimit)
        case .cursor:
            slice = RecentOutputReader.cursor(tail: data, limit: limit, perEntryLimit: perEntryLimit)
        default:
            let claude = RecentOutputReader.claude(
                tail: data, limit: limit, perEntryLimit: perEntryLimit)
            slice = claude.entries.isEmpty
                ? RecentOutputReader.codexRollout(tail: data, limit: limit, perEntryLimit: perEntryLimit)
                : claude
        }
        return finish(sessionID: sessionID, source: source, path: path, slice)
    }

    private func finish(
        sessionID: String,
        source: ObservationSource,
        path: String?,
        _ slice: RecentOutputSlice
    ) -> RecentOutput {
        RecentOutput(
            sessionId: sessionID,
            source: source,
            updatedAt: slice.updatedAt ?? path.flatMap(Self.modificationDate),
            truncated: slice.truncated,
            entries: slice.entries.map { RecentOutputEntry(role: $0.role, text: $0.text) })
    }

    private static func readTail(path: String, maxBytes: Int) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        do {
            let end = try handle.seekToEnd()
            let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
            try handle.seek(toOffset: start)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// Privacy-minimized lifecycle diagnostics, newest first.
    public func recentLifecycle(limit: Int = 40) -> [LifecycleJournalEntry] {
        lifecycleJournal?.recent(limit: limit) ?? []
    }

    /// Explicitly erase the lifecycle journal. Returns false and retains the
    /// in-memory timeline when on-disk data could not be removed, allowing retry.
    @discardableResult
    public func clearLifecycleJournal() -> Bool {
        let ledgerRemoved = toolLedger.clear()
        guard var journal = lifecycleJournal else { return ledgerRemoved }
        let removed = journal.clear()
        lifecycleJournal = journal
        return removed && ledgerRemoved
    }

    /// Subscribe to live snapshots. The current snapshot is delivered immediately.
    public func subscribe() -> (id: UUID, stream: AsyncStream<Snapshot>) {
        let id = UUID()
        let stream = AsyncStream<Snapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
        }
        subscribers[id]?.yield(currentSnapshot(now: Date()))
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    /// Open snapshot streams right now. Only `/ws` clients subscribe — a phone,
    /// or a debugging tool — so this is "could a phone be about to act on the
    /// snapshot just broadcast". It cannot say *which* phone, nor whether the
    /// app behind a socket is still running; `PhoneReceipts` answers that.
    public var subscriberCount: Int { subscribers.count }

    /// Bursts collapse on the way out: the first snapshot in a quiet window is
    /// delivered at once, later ones inside the window are replaced by a single
    /// trailing delivery of the newest. A transcript poll that yields three
    /// events for three sessions used to hand three 500 KB snapshots to every
    /// phone within a millisecond; the phone only ever acted on the last.
    ///
    /// Assembly itself is not coalesced: the recap ledger and completion
    /// results settle inside `currentSnapshot` and must see every state.
    static let broadcastWindow: Duration = .milliseconds(300)
    private var lastDeliveryAt: ContinuousClock.Instant?
    private var pendingDelivery: Snapshot?
    private var trailingDelivery: Task<Void, Never>?
    /// Snapshots actually handed to subscribers. Exposed for tests.
    private(set) var broadcastCount = 0

    private func broadcast() {
        let snapshot = currentSnapshot(now: Date())
        guard !subscribers.isEmpty else { return }
        let now = ContinuousClock.now
        if trailingDelivery != nil {
            pendingDelivery = snapshot
            return
        }
        if let last = lastDeliveryAt, now - last < Self.broadcastWindow {
            pendingDelivery = snapshot
            trailingDelivery = Task { [weak self] in
                try? await Task.sleep(for: Self.broadcastWindow)
                await self?.deliverTrailing()
            }
            return
        }
        deliver(snapshot, at: now)
    }

    private func deliverTrailing() {
        trailingDelivery = nil
        guard let snapshot = pendingDelivery else { return }
        pendingDelivery = nil
        deliver(snapshot, at: ContinuousClock.now)
    }

    private func deliver(_ snapshot: Snapshot, at now: ContinuousClock.Instant) {
        lastDeliveryAt = now
        broadcastCount += 1
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    @discardableResult
    private func appendJournal(
        sessionID: String,
        agent: AgentKind,
        event: String,
        source: ObservationSource,
        at timestamp: Date
    ) -> Bool {
        // Session IDs are normally UUID-sized. Refuse an untrusted oversized ID
        // so the record-count limit also remains a practical byte-size bound.
        guard sessionID.utf8.count <= 256 else { return false }
        guard var journal = lifecycleJournal else { return true }
        let result = reducer.sessions[sessionID]
        let persisted = journal.append(LifecycleJournalEntry(
            sessionID: sessionID,
            agent: agent,
            event: event,
            source: source,
            timestamp: timestamp,
            status: result?.status,
            waitKind: result?.waitKind,
            // The reducer's "—" placeholder means no cwd yet; don't persist it.
            // The entry itself bounds the label (LifecycleJournalEntry.maxProjectBytes).
            project: result.flatMap { $0.project == "—" ? nil : $0.project },
            completionID: result?.completionID,
            hasUnreadCompletion: result?.hasUnreadCompletion,
            statusSince: result?.statusSince,
            failed: result?.failed,
            acknowledgedCompletionID: result?.acknowledgedCompletionID
        ), now: timestamp)
        lifecycleJournal = journal
        return persisted
    }

    private func diagnostics(now: Date) -> [AgentObservationDiagnostic]? {
        let signals = runtimeSignals.values.flatMap { $0.values }
        guard diagnosticsHome != nil || !signals.isEmpty else { return nil }
        if let cache = diagnosticCache, now.timeIntervalSince(cache.at) < 30 {
            return cache.value
        }
        let value = ObservationHealthDetector.detect(
            home: diagnosticsHome, signals: signals, now: now,
            staleAfter: Self.diagnosticStaleAfter, grokHome: grokHome)
        diagnosticCache = (now, value)
        return value
    }

    private func recordSignal(
        agent: AgentKind,
        source: ObservationSource,
        at date: Date,
        health: ObservationHealth,
        coverage: ObservationEventCoverage?
    ) {
        var perSource = runtimeSignals[agent] ?? [:]
        let previous = perSource[source]
        var signal = previous ?? ObservationRuntimeSignal(
            agent: agent, source: source, lastObservedAt: date, health: health)
        if date >= signal.lastObservedAt {
            signal.lastObservedAt = date
            signal.health = health
        }
        if let coverage {
            signal.observedCoverage = Array(Set(signal.observedCoverage).union([coverage])).sorted()
        }
        perSource[source] = signal
        runtimeSignals[agent] = perSource
        let patchedCache = patchDiagnosticCache(with: signal)
        // Static compatibility evidence is comparatively expensive to inspect.
        // Rebuild it when a source first appears or its state/coverage changes;
        // ordinary timestamp advances can use the bounded 30-second cache.
        if !patchedCache && (previous == nil
            || previous?.health != signal.health
            || previous?.observedCoverage != signal.observedCoverage) {
            diagnosticCache = nil
        }
    }

    /// Patch freshness-only rows in memory. Static compatibility failures still
    /// invalidate once when the runtime signal materially changes.
    private func patchDiagnosticCache(with signal: ObservationRuntimeSignal) -> Bool {
        guard var cache = diagnosticCache,
              let agentIndex = cache.value.firstIndex(where: { $0.agent == signal.agent }),
              let sourceIndex = cache.value[agentIndex].sources
                .firstIndex(where: { $0.source == signal.source }) else { return false }
        var row = cache.value[agentIndex].sources[sourceIndex]
        guard row.health == .healthy || row.health == .temporarilySilent else { return false }

        if row.reasonCode == "awaitingActivity" { row.reasonCode = nil }
        row.lastObservedAt = max(row.lastObservedAt ?? signal.lastObservedAt,
                                 signal.lastObservedAt)
        row.observedCoverage = Array(
            Set(row.observedCoverage).union(signal.observedCoverage)).sorted()
        if signal.health != .healthy {
            row.health = signal.health
            if signal.source == .rollout, signal.health == .unknownVersion {
                row.reasonCode = "invalidSourceData"
            }
        } else {
            row.health = cache.at.timeIntervalSince(signal.lastObservedAt)
                > Self.diagnosticStaleAfter ? .temporarilySilent : .healthy
        }
        cache.value[agentIndex].sources[sourceIndex] = row
        diagnosticCache = cache
        return true
    }

    private static func coverage(for kind: HookEvent.Kind) -> ObservationEventCoverage {
        if kind == .userPromptSubmit || kind == .stop { return .turn }
        if kind == .preToolUse || kind == .postToolUse { return .tool }
        if kind == .notification { return .attention }
        return .lifecycle
    }

    private static func sourceHealth(at path: String) -> ObservationHealth {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              fm.isReadableFile(atPath: path),
              let attributes = try? fm.attributesOfItem(atPath: path),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o444 != 0
        else { return .sourceUnreadable }
        return .healthy
    }
}
