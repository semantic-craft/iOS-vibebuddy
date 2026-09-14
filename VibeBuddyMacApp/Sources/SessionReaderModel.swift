import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// What the reading pane is looking at: a live session, a history record,
/// or one session seen from both sides. Built by the list that selected it;
/// the pane never guesses the other half by title.
struct ReaderSubject: Equatable {
    enum Origin: Equatable { case live, history }
    var origin: Origin
    var live: AgentSession?
    /// The history library's row for the same native id, when it has one.
    var record: SessionHistorySession?

    var id: String { live?.id ?? record?.id ?? "" }
    var title: String { live?.taskGoal ?? record?.title ?? "" }
    var agent: AgentKind {
        if let live { return live.agent }
        switch record?.agent {
        case .claude: return .claudeCode
        case .codex: return .codex
        case .cursor: return .cursor
        case .grokBuild, .none: return .grok
        }
    }
    var projectName: String { live?.project ?? record.map { URL(fileURLWithPath: $0.projectPath).lastPathComponent } ?? "" }
    var projectPath: String? { live?.checkoutPath ?? live?.terminalRef?.cwd ?? record?.projectPath }

    /// The key `readTranscript(key:)` accepts, from whichever side has it.
    var transcriptKey: String? {
        if let live { return SessionReaderSource.transcriptKey(for: live) }
        guard let record, record.agent.supportsTranscript else { return nil }
        return record.agent.keyName + ":" + record.nativeSessionID
    }
}

/// Loads the body for a subject (ADR-0024): the agent's local transcript by
/// exact key, else the daemon's bounded excerpt. Watches the transcript file
/// while a subject is open so an appended turn shows without a poll, and
/// throws away any result that lands after the subject changed.
@MainActor
final class SessionReaderModel: ObservableObject {
    enum Body: Equatable {
        case empty
        case transcript(provenance: String, updatedAt: Date, sourcePath: String, isAvailable: Bool)
        case recentOutput(sourceLabel: String, statusLine: String, updatedAt: Date?)
        case unsupported(String)
    }

    @Published private(set) var rows: [HistoryMessageRow] = []
    @Published private(set) var body: Body = .empty
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var subjectID: String?

    private let history: HistoryLibraryModel
    private let model: MenuBarModel
    private var generation = 0
    private var watcher: TranscriptFileWatcher?
    private var current: ReaderSubject?
    private var target: String?

    init(history: HistoryLibraryModel, model: MenuBarModel) {
        self.history = history
        self.model = model
    }

    /// Called whenever the selection, the target message, or the live
    /// session's status changes. A same-subject reload keeps the rows on
    /// screen until the new ones arrive, so the window can detect an append.
    func load(_ subject: ReaderSubject?, target: String?) async {
        generation += 1
        let generation = generation
        guard let subject else {
            current = nil; subjectID = nil; rows = []; body = .empty; error = nil; loading = false
            watcher = nil
            return
        }
        let sameSubject = current?.id == subject.id
        current = subject
        self.target = target
        if !sameSubject { rows = []; body = .empty; watcher = nil }
        subjectID = subject.id
        error = nil
        loading = rows.isEmpty
        defer { if generation == self.generation { loading = false } }

        if subject.origin == .history, let record = subject.record {
            await history.read(record.id)
            guard generation == self.generation, !Task.isCancelled else { return }
            if let readingError = history.readingError { error = readingError; return }
            guard let loaded = history.transcript, loaded.id == record.id else { return }
            if !record.agent.supportsTranscript {
                body = .unsupported(String(localized: "This source provides a session list and titles only."))
                rows = []
                return
            }
            let projected = await Self.project(loaded.messages, revealing: target)
            guard generation == self.generation, !Task.isCancelled else { return }
            rows = projected
            body = .transcript(provenance: "source or revision-checked cache", updatedAt: loaded.updatedAt, sourcePath: loaded.sourcePath,
                               isAvailable: record.isAvailable && loaded.isAvailable)
            watch(path: loaded.sourcePath)
            return
        }

        if let key = subject.transcriptKey, !history.isDemo {
            do {
                let transcript = try await history.readTranscript(key: key)
                guard generation == self.generation, !Task.isCancelled else { return }
                let projected = await Self.project(transcript.session.messages, revealing: target)
                guard generation == self.generation, !Task.isCancelled else { return }
                rows = projected
                body = .transcript(provenance: transcript.provenance, updatedAt: transcript.session.updatedAt,
                                   sourcePath: transcript.session.sourcePath, isAvailable: transcript.session.isAvailable)
                watch(path: transcript.session.sourcePath)
                return
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                // No transcript for this id yet (or none readable): the excerpt below is the honest fallback.
            }
        }
        guard let live = subject.live else {
            body = .unsupported(String(localized: "This source provides a session list and titles only."))
            rows = []
            return
        }
        let output = await model.recentOutput(for: live.id)
        guard generation == self.generation, !Task.isCancelled else { return }
        rows = output.entries.enumerated().map { index, entry in
            HistoryMessageRow.standalone(id: "recent-\(index)", role: entry.role == "assistant" ? .assistant : .user, text: entry.text)
        }
        body = .recentOutput(sourceLabel: output.sourceLabel, statusLine: output.statusLine, updatedAt: output.updatedAt)
    }

    /// Re-read the open subject in place (the file changed, or the person asked).
    func refresh() {
        guard let current else { return }
        let generation = generation
        Task {
            guard generation == self.generation else { return }
            await load(current, target: target)
        }
    }

    private func watch(path: String) {
        if watcher?.path == path { return }
        watcher = TranscriptFileWatcher(path: path) { [weak self] in self?.refresh() }
    }

    private nonisolated static func project(_ messages: [SessionHistoryMessage], revealing target: String?) async -> [HistoryMessageRow] {
        await Task.detached(priority: .userInitiated) { SessionHistoryPresentation.rows(messages, revealing: target) }.value
    }
}
