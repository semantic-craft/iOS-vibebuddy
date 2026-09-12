import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeBuddyKit
import VibeBuddyMacCore

/// The history library never inserts archived records into the live snapshot.
@MainActor
final class HistoryLibraryModel: ObservableObject {
    @Published private(set) var snapshot = SessionHistorySnapshot()
    @Published private(set) var results: [SessionHistorySearchResult] = []
    @Published private(set) var loading = false
    @Published private(set) var searching = false
    @Published private(set) var searchError: String?
    @Published var error: String?
    @Published private(set) var transcript: SessionHistorySession?
    @Published private(set) var readingError: String?
    @Published private(set) var reading = false
    @Published private(set) var summary: SessionHistorySummary?
    @Published private(set) var summarizing = false
    @Published private(set) var summaryError: String?
    private let summaryService = SessionHistorySummaryService()
    private var summaryTask: Task<Void, Never>?
    private var readGeneration = 0
    private let repository: SessionHistoryRepository
    private var searchGeneration = 0

    init() {
        let environment = ProcessInfo.processInfo.environment
        if let root = environment["VIBEBUDDY_E2E_ROOT"] {
            let url = URL(fileURLWithPath: root)
            repository = SessionHistoryRepository(
                claudeHome: url.appendingPathComponent("agents/claude"),
                codexHome: url.appendingPathComponent("agents/codex"),
                cacheDirectory: url.appendingPathComponent("history"))
        } else {
            repository = SessionHistoryRepository()
        }
    }

    func refresh(rebuild: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            snapshot = try await repository.refresh(rebuild: rebuild)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func search(_ query: String, project: String?, favorites: Bool, agent: SessionHistoryAgent?, archived: Bool?) async {
        searchGeneration += 1
        let generation = searchGeneration
        searching = true
        // Clear old query results immediately; delayed queries must never overwrite newer ones.
        results = []
        searchError = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searching = false
            return
        }
        do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        guard !Task.isCancelled else { return }
        do {
            let found = try await repository.search(query, projectPath: project, favoritesOnly: favorites, agent: agent, archived: archived, limit: 200)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = found
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
        searching = false
    }

    func read(_ id: String?) async {
        readGeneration += 1
        let generation = readGeneration
        readingError = nil
        summaryTask?.cancel(); summaryTask = nil; summarizing = false; summary = nil; summaryError = nil
        guard let id else { transcript = nil; reading = false; return }
        if transcript?.id != id { transcript = nil }
        reading = true
        do {
            let result = try await repository.session(id: id)
            guard generation == readGeneration, !Task.isCancelled else { return }
            transcript = result
            do {
                let saved = try await repository.summary(sessionID: id)
                if generation == readGeneration { summary = saved }
            } catch { if generation == readGeneration { summaryError = "Saved summary could not be read. You can generate it again." } }
            if result == nil { readingError = "This record is no longer indexed. Refresh the library." }
        } catch {
            guard generation == readGeneration, !Task.isCancelled else { return }
            readingError = error.localizedDescription
        }
        if generation == readGeneration { reading = false }
    }

    func generateSummary() {
        guard !summarizing, let selected = transcript else { return }
        let generation = readGeneration
        let config = CompletionSummaryConfiguration.load()
        let style = HistorySummaryStyle.load()
        summarizing = true; summaryError = nil
        summaryTask = Task {
            defer { if generation == readGeneration { summarizing = false } }
            do {
                let result = try await summaryService.generate(selected, configuration: config, style: style)
                guard generation == readGeneration, !Task.isCancelled else { return }
                try await repository.saveSummary(result)
                guard generation == readGeneration, !Task.isCancelled else { return }
                summary = result
            } catch is CancellationError { }
            catch let failure as CompletionSummaryFailure {
                guard generation == readGeneration, !Task.isCancelled else { return }
                switch failure {
                case .missingProvider, .missingModel, .missingKey, .invalidModel, .invalidWorkspace:
                    summaryError = "Configure the summary provider, text model and API key in Settings."
                default: summaryError = "Summary could not be generated (\(failure.rawValue)). You can retry."
                }
            } catch {
                if generation == readGeneration, !Task.isCancelled { summaryError = "Could not save the summary. You can retry." }
            }
        }
    }
    func cancelSummary() { summaryTask?.cancel() }

    func togglePinned(_ session: SessionHistorySession) async {
        do {
            try await repository.setPinned(sessionID: session.id, isPinned: session.isPinned != true)
            snapshot = await repository.snapshot()
        } catch { self.error = error.localizedDescription }
    }
    func toggleArchive(_ session: SessionHistorySession) async {
        do {
            try await repository.setArchived(sessionID: session.id, isArchived: session.archivedLocally != true)
            snapshot = await repository.snapshot()
        } catch { self.error = error.localizedDescription }
    }

    func toggleFavorite(_ session: SessionHistorySession) async {
        do {
            try await repository.setFavorite(sessionID: session.id, isFavorite: !session.isFavorite)
            snapshot = await repository.snapshot()
            if transcript?.id == session.id { transcript?.isFavorite = !session.isFavorite }
        } catch { self.error = error.localizedDescription }
    }
}

struct HistoryWorkbenchView: View {
    @ObservedObject var history: HistoryLibraryModel
    @ObservedObject var model: MenuBarModel
    let query: String
    let favoritesOnly: Bool
    @State private var project: String?
    @State private var agent: SessionHistoryAgent?
    @State private var archiveScope = "all"
    private var archived: Bool? { archiveScope == "all" ? nil : archiveScope == "archived" }
    @State private var selection: String?
    @State private var targetMessage: String?
    @State private var exportError: String?

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var sessions: [SessionHistorySession] {
        history.snapshot.sessions.filter {
            (project == nil || $0.projectPath == project) && (!favoritesOnly || $0.isFavorite)
                && (agent == nil || $0.agent == agent) && (archived == nil || $0.isArchived == archived)
        }
    }
    private var projects: [String] {
        Array(Set(history.snapshot.sessions.map(\.projectPath))).sorted()
    }
    private var selected: SessionHistorySession? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection }
    }
    private var readKey: String {
        guard let selected else { return "" }
        return "\(selected.id)|\(selected.sourcePath)|\(selected.sourceRevision ?? "")|\(selected.updatedAt.timeIntervalSince1970)|\(selected.isAvailable)"
    }
    private var searchKey: String {
        "\(agent?.rawValue ?? "")|\(archiveScope)|\(sessions.map { "\($0.id):\($0.isFavorite):\($0.isArchived)" }.joined(separator: ","))|\(query)\u{1f}\(project ?? "")\u{1f}\(favoritesOnly)\u{1f}\(history.snapshot.refreshedAt?.timeIntervalSince1970 ?? 0)\u{1f}\(sessions.filter(\.isFavorite).count)"
    }

    var body: some View {
        HSplitView {
            sidebar
            sessionList
            readingPane
        }
        .task {
            await history.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await history.refresh()
            }
        }
        .task(id: searchKey) { await history.search(query, project: project, favorites: favoritesOnly, agent: agent, archived: archived) }
        .task(id: readKey) { await history.read(selected?.id) }
        .onChange(of: agent) { _, _ in clearSelection() }
        .onChange(of: archiveScope) { _, _ in clearSelection() }
        .onChange(of: project) { _, _ in clearSelection() }
        .onChange(of: favoritesOnly) { _, _ in clearSelection() }
        .onChange(of: query) { _, _ in clearSelection() }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { clearSelection() }
        }
        .alert("Could not export", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Local library").font(MacTheme.font(13, .semibold))
            Text("Claude Code · Codex\nIncludes archived Codex sessions")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            Picker("Agent", selection: $agent) {
                Text("All agents").tag(nil as SessionHistoryAgent?)
                ForEach(SessionHistoryAgent.allCases, id: \.self) { value in
                    Text(value.displayName).tag(Optional(value))
                }
            }
            Picker("Archive", selection: $archiveScope) {
                Text("All history").tag("all")
                Text("Unarchived").tag("unarchived")
                Text("Archived").tag("archived")
            }
            Button { project = nil } label: {
                Label("All projects", systemImage: "tray.full")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(project == nil ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
            }.buttonStyle(.plain)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(projects, id: \.self) { path in
                        Button { project = path } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(path.isEmpty ? "Unknown project" : URL(fileURLWithPath: path).lastPathComponent,
                                      systemImage: "folder")
                                Text(path).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            .background(project == path ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).help(path)
                    }
                }
            }
            Divider()
            if history.loading { ProgressView("Updating library…").font(MacTheme.font(10)) }
            if let date = history.snapshot.refreshedAt {
                Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            }
            HStack {
                Button("Refresh") { Task { await history.refresh() } }
                Menu {
                    Button("Rebuild index") { Task { await history.refresh(rebuild: true) } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 24)
            }.disabled(history.loading)
            if let error = history.error { Text(error).font(MacTheme.font(10)).foregroundStyle(.red).textSelection(.enabled) }
            if !history.snapshot.issues.isEmpty {
                DisclosureGroup("Source notices (\(history.snapshot.issues.count))") {
                    ScrollView { Text(history.snapshot.issues.joined(separator: "\n")).font(MacTheme.font(10)).textSelection(.enabled) }
                        .frame(maxHeight: 130)
                }.font(MacTheme.font(10))
            }
        }
        .padding(12).frame(minWidth: 170, idealWidth: 210, maxWidth: 270)
        .frame(maxHeight: .infinity).background(Color(nsColor: .controlBackgroundColor))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isSearching ? "Message matches" : favoritesOnly ? "Favorites" : "History").font(MacTheme.font(13, .semibold))
                Spacer()
                Text("\(isSearching ? history.results.count : sessions.count)").foregroundStyle(MacTheme.ink2)
            }.padding(12)
            if isSearching && history.searching { ProgressView("Searching…") }
            if isSearching, let error = history.searchError {
                Text("Search could not complete: \(error)").font(MacTheme.font(10)).foregroundStyle(.red).padding(12)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if isSearching {
                        ForEach(history.results) { hit in
                            if let session = sessions.first(where: { $0.id == hit.sessionID }) {
                                Button {
                                    selection = session.id
                                    targetMessage = hit.messageID
                                } label: { row(session, excerpt: hit.excerpt, active: selection == session.id && targetMessage == hit.messageID) }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(sessions) { session in
                            Button { selection = session.id; targetMessage = nil } label: {
                                row(session, excerpt: nil, active: selection == session.id)
                            }.buttonStyle(.plain)
                        }
                    }
                    if !history.loading && !(isSearching && history.searching) && (isSearching ? history.results.isEmpty && history.searchError == nil : sessions.isEmpty) {
                        ContentUnavailableView(isSearching ? "No matching messages" : "No sessions in this view", systemImage: "text.magnifyingglass",
                                               description: Text("Check the project filter and source notices, or refresh the library."))
                    }
                }.padding(.horizontal, 8)
            }
            if isSearching && history.results.count == 200 {
                Text("Showing the first 200 matches. Narrow your query or project.").font(MacTheme.font(10)).padding(8)
            }
        }.frame(minWidth: 230, idealWidth: 300, maxWidth: 380)
    }

    private func row(_ session: SessionHistorySession, excerpt: String?, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(session.title).font(MacTheme.font(13, .medium)).lineLimit(2)
                if session.isPinned == true { Image(systemName: "pin.fill").foregroundStyle(MacTheme.ink2) }
                if session.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
            Text("\(session.agent.displayName) · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            if session.isArchived { Label(session.sourceArchived == true ? "Archived in Codex" : "Archived in library", systemImage: "archivebox").font(MacTheme.font(10)) }
            if let excerpt { Text(excerpt).font(MacTheme.font(10)).lineLimit(3) }
            if !session.isAvailable { Label("Source unavailable", systemImage: "exclamationmark.triangle").font(MacTheme.font(10)) }
            else if !session.warnings.isEmpty { Label("Partial or limited record", systemImage: "info.circle").font(MacTheme.font(10)) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(active ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    @ViewBuilder private var readingPane: some View {
        if let metadata = selected {
            let session = readingSession(metadata)
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.title).font(MacTheme.font(17, .semibold)).textSelection(.enabled).lineLimit(3)
                    Text("\(session.agent.displayName) · \(session.projectPath)").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2).textSelection(.enabled)
                    ViewThatFits(in: .horizontal) {
                        HStack { sessionActions(session) }
                        VStack(alignment: .leading) { sessionActions(session) }
                    }
                    HistorySessionActions(session: session, model: model)
                    ForEach(session.warnings, id: \.self) { warning in
                        Text(warning).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                    if !session.isAvailable {
                        Text("The source is unavailable. Showing the last indexed copy.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                if history.reading && history.transcript?.id != metadata.id {
                    ProgressView("Reading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = history.readingError {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(MacTheme.ink2)
                        Button("Retry") { Task { await history.read(metadata.id) } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HistorySummaryView(history: history, session: session)
                        Divider()
                        HistoryMessageReader(session: session, targetMessage: targetMessage)
                    }
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            .id(session.id)
        } else {
            ContentUnavailableView("Select a conversation", systemImage: "text.book.closed",
                                   description: Text("Read local history without changing a task's live state."))
                .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func readingSession(_ metadata: SessionHistorySession) -> SessionHistorySession {
        var value = metadata
        if let loaded = history.transcript, loaded.id == metadata.id, loaded.sourcePath == metadata.sourcePath {
            value.messages = loaded.messages
            value.isAvailable = metadata.isAvailable && loaded.isAvailable
        }
        return value
    }

    @ViewBuilder private func sessionActions(_ session: SessionHistorySession) -> some View {
        Button { Task { await history.toggleFavorite(session) } } label: {
            Label(session.isFavorite ? "Unfavorite" : "Favorite", systemImage: session.isFavorite ? "star.fill" : "star")
        }
        Button(session.isPinned == true ? "Unpin" : "Pin") { Task { await history.togglePinned(session) } }
        Button(session.archivedLocally == true ? "Unarchive in library" : "Archive in library") {
            Task { await history.toggleArchive(session) }
        }.help("Organizes this library only; the original agent and current tasks are unchanged.")
        Button("Export Markdown…") { export(session) }
            .disabled(history.reading || history.transcript?.id != session.id || history.readingError != nil)
        Button("Show source") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.sourcePath)]) }
            .disabled(!session.isAvailable)
    }

    private func clearSelection() { selection = nil; targetMessage = nil }

    private func export(_ session: SessionHistorySession) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(session.agent.rawValue)-\(session.nativeSessionID).md"
        panel.canCreateDirectories = true
        if let root = E2ERunConfiguration.current?.root { panel.directoryURL = root }
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try SessionHistoryExport.markdown(session: session).write(to: url, atomically: true, encoding: .utf8) }
            catch { exportError = error.localizedDescription }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
