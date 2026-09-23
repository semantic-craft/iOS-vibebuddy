import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// What the reading pane is looking at: one live session. The transcript
/// is found by the session's exact native id, never by title.
struct ReaderSubject: Equatable {
    var live: AgentSession

    var id: String { live.id }
    var title: String { live.taskGoal }
    var agent: AgentKind { live.agent }
    var projectName: String { live.project }
    var projectPath: String? { live.checkoutPath ?? live.terminalRef?.cwd }

    /// The key `SessionTranscriptReader.readTranscript(key:)` accepts.
    var transcriptKey: String? { SessionReaderSource.transcriptKey(for: live) }
}

/// Loads the body for a subject (ADR-0024): the agent's local transcript by
/// exact key, else the daemon's bounded excerpt. Watches the transcript file
/// while a subject is open so an appended turn shows without a poll, and
/// throws away any result that lands after the subject changed.
@MainActor
final class SessionReaderModel: ObservableObject {
    enum Body: Equatable {
        case empty
        case transcript(provenance: String, updatedAt: Date, sourcePath: String)
        case recentOutput(sourceLabel: String, statusLine: String, updatedAt: Date?)
    }

    @Published private(set) var rows: [HistoryMessageRow] = []
    @Published private(set) var body: Body = .empty
    @Published private(set) var transcript: SessionHistorySession?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var subjectID: String?

    private let transcripts = SessionTranscriptReader.forCurrentRun()
    /// The demo reads no agent files; its sessions show their recent output.
    private let isDemo = ProcessInfo.processInfo.environment["VIBEBUDDY_E2E_ROOT"] == nil
        && ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1"
    private let model: MenuBarModel
    private var generation = 0
    private var watcher: TranscriptFileWatcher?
    private var current: ReaderSubject?
    private var target: String?

    init(model: MenuBarModel) {
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
            watcher = nil; transcript = nil
            return
        }
        let sameSubject = current?.id == subject.id
        current = subject
        self.target = target
        if !sameSubject { rows = []; body = .empty; watcher = nil; transcript = nil }
        subjectID = subject.id
        error = nil
        loading = rows.isEmpty
        defer { if generation == self.generation { loading = false } }

        if let key = subject.transcriptKey, !isDemo {
            do {
                let transcript = try await transcripts.readTranscript(key: key)
                guard generation == self.generation, !Task.isCancelled else { return }
                let projected = await Self.project(transcript.session.messages, revealing: target)
                guard generation == self.generation, !Task.isCancelled else { return }
                rows = projected
                self.transcript = transcript.session
                body = .transcript(provenance: transcript.provenance, updatedAt: transcript.session.updatedAt,
                                   sourcePath: transcript.session.sourcePath)
                watch(path: transcript.session.sourcePath)
                return
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                // No transcript for this id yet (or none readable): the excerpt below is the honest fallback.
            }
        }
        transcript = nil
        let live = subject.live
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
