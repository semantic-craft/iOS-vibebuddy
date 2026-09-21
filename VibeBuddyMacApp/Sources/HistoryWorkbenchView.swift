import AppKit
import SwiftUI
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
    /// A second, read-only actor over the same roots and cache for the reader's
    /// transcript reads, so opening a conversation never queues behind the
    /// index refresh the writer actor is running (ADR-0024).
    private let readerRepository: SessionHistoryRepository
    private var readerMetadataStamp: Date?
    private var searchGeneration = 0
    let isDemo: Bool
    private var observationGeneration = 0
    private var directoryWatcher: HistoryDirectoryWatcher?
    private var pendingHistoryPaths = Set<String>()
    private var reconcileHistory = false
    private var rebuildHistory = false
    private var continueHistoryBatch = false
    private var retryHistoryAfter = Date.distantPast

    init() {
        let environment = ProcessInfo.processInfo.environment
        isDemo = environment["VIBEBUDDY_E2E_ROOT"] == nil && environment["VIBEBUDDY_DEMO"] == "1"
        if let root = environment["VIBEBUDDY_E2E_ROOT"] {
            let url = URL(fileURLWithPath: root)
            let make = { (readOnly: Bool) in
                SessionHistoryRepository(
                    claudeHome: url.appendingPathComponent("agents/claude"),
                    codexHome: url.appendingPathComponent("agents/codex"),
                    cursorHome: url.appendingPathComponent("agents/cursor"),
                    grokHome: url.appendingPathComponent("agents/grok"),
                    cacheDirectory: url.appendingPathComponent("history"), readOnly: readOnly)
            }
            repository = make(false)
            readerRepository = make(true)
        } else {
            repository = SessionHistoryRepository(grokHome: isDemo ? nil : GrokHome.url, readOnly: isDemo)
            readerRepository = SessionHistoryRepository(grokHome: isDemo ? nil : GrokHome.url, readOnly: true)
        }
        if isDemo { snapshot = SessionHistorySnapshot(sessions: MacDemoData.historySessions(), refreshedAt: Date()) }
    }

    func refresh(rebuild: Bool = false) async {
        guard !isDemo else { return }
        reconcileHistory = true
        rebuildHistory = rebuildHistory || rebuild
        retryHistoryAfter = .distantPast
        await drainHistory(generation: observationGeneration)
    }

    func observeHistory() async {
        guard !isDemo else { return }
        directoryWatcher?.stop()
        directoryWatcher = nil
        observationGeneration += 1
        let generation = observationGeneration
        let roots = await repository.observationRoots()
        guard !Task.isCancelled, generation == observationGeneration else { return }
        let watcher = HistoryDirectoryWatcher(roots: roots) { [weak self] changes in
            guard let self, self.observationGeneration == generation else { return }
            self.pendingHistoryPaths.formUnion(changes.paths)
            self.reconcileHistory = self.reconcileHistory || changes.requiresReconciliation || self.pendingHistoryPaths.count > 4096
            if self.pendingHistoryPaths.count > 4096 {
                self.pendingHistoryPaths = Set(self.pendingHistoryPaths.sorted().prefix(4096))
            }
        }
        directoryWatcher = watcher
        defer {
            watcher.stop()
            if generation == observationGeneration {
                directoryWatcher = nil
                observationGeneration += 1
                pendingHistoryPaths.removeAll()
                reconcileHistory = false
                rebuildHistory = false
                continueHistoryBatch = false
            }
        }
        reconcileHistory = true
        var nextReconciliation = Date().addingTimeInterval(30)
        await withTaskCancellationHandler {
            while !Task.isCancelled, generation == observationGeneration {
                if Date() >= nextReconciliation {
                    reconcileHistory = true
                    nextReconciliation = Date().addingTimeInterval(30)
                }
                await drainHistory(generation: generation)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        } onCancel: {
            Task { @MainActor [weak watcher] in watcher?.stop() }
        }
    }

    private func drainHistory(generation: Int) async {
        guard !loading, Date() >= retryHistoryAfter,
              reconcileHistory || !pendingHistoryPaths.isEmpty || continueHistoryBatch else { return }
        let paths = pendingHistoryPaths
        let reconcile = reconcileHistory
        let rebuild = rebuildHistory
        pendingHistoryPaths.removeAll()
        reconcileHistory = false
        rebuildHistory = false
        continueHistoryBatch = false
        loading = true
        defer { loading = false }
        do {
            let updated: SessionHistorySnapshot
            if reconcile {
                updated = try await repository.refresh(rebuild: rebuild, failIfBusy: true)
            } else {
                updated = try await repository.refresh(changedPaths: paths)
            }
            guard generation == observationGeneration, !Task.isCancelled else { return }
            snapshot = updated
            if reconcile {
                pendingHistoryPaths.formUnion(paths)
                if pendingHistoryPaths.count > 4096 {
                    reconcileHistory = true
                    pendingHistoryPaths = Set(pendingHistoryPaths.sorted().prefix(4096))
                }
            }
            continueHistoryBatch = updated.pendingSourceCount > 0
            error = nil
        } catch {
            guard generation == observationGeneration, !Task.isCancelled else { return }
            pendingHistoryPaths.formUnion(paths)
            reconcileHistory = reconcileHistory || reconcile || pendingHistoryPaths.count > 4096
            if pendingHistoryPaths.count > 4096 {
                pendingHistoryPaths = Set(pendingHistoryPaths.sorted().prefix(4096))
            }
            rebuildHistory = rebuildHistory || rebuild
            continueHistoryBatch = true
            retryHistoryAfter = Date().addingTimeInterval(2)
            self.error = error.localizedDescription
        }
    }

    func search(_ query: String, project: String?, favorites: Bool, agent: SessionHistoryAgent?, archived: Bool?) async {
        if isDemo {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            results = needle.isEmpty ? [] : Array(snapshot.sessions.filter {
                (project == nil || $0.projectPath == project) && (!favorites || $0.isFavorite)
                    && (agent == nil || $0.agent == agent) && (archived == nil || $0.isArchived == archived)
            }.flatMap { session in
                session.messages.filter { $0.kind != .meta && $0.kind != .thinking && $0.text.localizedCaseInsensitiveContains(needle) }
                    .map { SessionHistorySearchResult(sessionID: session.id, messageID: $0.id, excerpt: String($0.text.prefix(240))) }
            }.prefix(200))
            searching = false; searchError = nil
            return
        }
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
            try await readerRepository.reloadReadOnlyMetadata()
            let found = try await readerRepository.search(query, projectPath: project, favoritesOnly: favorites, agent: agent, archived: archived, limit: 200)
            guard generation == searchGeneration, !Task.isCancelled else { return }
            results = found
        } catch {
            guard generation == searchGeneration, !Task.isCancelled else { return }
            searchError = error.localizedDescription
        }
        searching = false
    }

    /// A transcript by exact key, fresh from the source when the index is
    /// stale (ADR-0024). Read only; never refreshes or publishes the index.
    func readTranscript(key: String) async throws -> HistoryTranscript {
        guard !isDemo else { throw HistoryToolError.executionFailed("Demo mode reads no transcripts.") }
        // Pick up the writer's latest published metadata once per refresh, not per read.
        if let stamp = snapshot.refreshedAt, stamp != readerMetadataStamp {
            try await readerRepository.reloadReadOnlyMetadata()
            readerMetadataStamp = stamp
        }
        return try await readerRepository.readTranscript(key: key)
    }

    func read(_ id: String?) async {
        readGeneration += 1
        let generation = readGeneration
        readingError = nil
        summaryTask?.cancel(); summaryTask = nil; summarizing = false; summary = nil; summaryError = nil
        guard let id else { transcript = nil; reading = false; return }
        if isDemo { transcript = snapshot.sessions.first { $0.id == id }; reading = false; return }
        if transcript?.id != id { transcript = nil }
        reading = true
        do {
            let result: SessionHistorySession?
            if let record = snapshot.sessions.first(where: { $0.id == id }), record.agent.supportsTranscript {
                // The watcher must see source changes immediately, without
                // waiting for the next index publication (Wake's reader rule).
                var fresh = try await readTranscript(key: record.agent.keyName + ":" + record.nativeSessionID).session
                fresh.isFavorite = record.isFavorite
                fresh.isPinned = record.isPinned
                fresh.archivedLocally = record.archivedLocally
                fresh.sourceArchived = record.sourceArchived
                result = fresh
            } else {
                result = try await repository.session(id: id)
            }
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
        guard !isDemo, !summarizing, let selected = transcript, selected.agent.supportsTranscript else { return }
        let generation = readGeneration
        let config = CompletionSummaryConfiguration.load()
        guard config.contentStyle.isValid else {
            summaryError = "Enter custom instructions in Settings before generating a summary."
            return
        }
        summarizing = true; summaryError = nil
        summaryTask = Task {
            defer { if generation == readGeneration { summarizing = false } }
            do {
                let result = try await summaryService.generate(selected, configuration: config)
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
        if isDemo { updateDemo(session.id) { $0.isPinned = $0.isPinned != true }; return }
        do {
            try await repository.setPinned(sessionID: session.id, isPinned: session.isPinned != true)
            snapshot = await repository.snapshot()
        } catch { self.error = error.localizedDescription }
    }
    func toggleArchive(_ session: SessionHistorySession) async {
        if isDemo { updateDemo(session.id) { $0.archivedLocally = $0.archivedLocally != true }; return }
        do {
            try await repository.setArchived(sessionID: session.id, isArchived: session.archivedLocally != true)
            snapshot = await repository.snapshot()
        } catch { self.error = error.localizedDescription }
    }

    func toggleFavorite(_ session: SessionHistorySession) async {
        if isDemo { updateDemo(session.id) { $0.isFavorite.toggle() }; return }
        do {
            try await repository.setFavorite(sessionID: session.id, isFavorite: !session.isFavorite)
            snapshot = await repository.snapshot()
            if transcript?.id == session.id { transcript?.isFavorite = !session.isFavorite }
        } catch { self.error = error.localizedDescription }
    }

    private func updateDemo(_ id: String, change: (inout SessionHistorySession) -> Void) {
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&snapshot.sessions[index])
        if transcript?.id == id { transcript = snapshot.sessions[index] }
    }
}

struct HistoryWorkbenchView: View {
    @ObservedObject var history: HistoryLibraryModel
    @ObservedObject var model: MenuBarModel
    @ObservedObject var reader: SessionReaderModel
    @Binding var query: String
    let favoritesOnly: Bool
    /// The sidebar owns the project choice (shared with the live library).
    @Binding var project: String?
    var searchFocused: FocusState<Bool>.Binding
    /// The list's compact flag, owned by the dashboard (one owner for ⌘F,
    /// the strip's search glyph and the split's own drag / double-click).
    @Binding var listCompact: Bool
    @State private var agent: SessionHistoryAgent?
    @State private var archiveScope = "all"
    private var archived: Bool? { archiveScope == "all" ? nil : archiveScope == "archived" }
    @State private var selection: String?
    @State private var targetMessage: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var archiveTitle: String {
        switch archiveScope {
        case "unarchived": String(localized: "Unarchived")
        case "archived": String(localized: "Archived")
        default: String(localized: "All history")
        }
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var sessions: [SessionHistorySession] {
        history.snapshot.sessions.filter {
            (project == nil || $0.projectPath == project) && (!favoritesOnly || $0.isFavorite)
                && (agent == nil || $0.agent == agent) && (archived == nil || $0.isArchived == archived)
        }
    }
    private var selected: SessionHistorySession? {
        guard let selection else { return nil }
        return sessions.first { $0.id == selection }
    }
    private var searchKey: String {
        "\(agent?.rawValue ?? "")|\(archiveScope)|\(sessions.map { "\($0.id):\($0.isFavorite):\($0.isArchived)" }.joined(separator: ","))|\(query)\u{1f}\(project ?? "")\u{1f}\(favoritesOnly)\u{1f}\(history.snapshot.refreshedAt?.timeIntervalSince1970 ?? 0)\u{1f}\(sessions.filter(\.isFavorite).count)"
    }

    var body: some View {
        ResizableListSplit(compact: $listCompact) { labels in sessionList(labels) } reader: { readingPane }
        .task(id: searchKey) { await history.search(query, project: project, favorites: favoritesOnly, agent: agent, archived: archived) }
        .onChange(of: agent) { _, _ in clearSelection() }
        .onChange(of: archiveScope) { _, _ in clearSelection() }
        .onChange(of: project) { _, _ in clearSelection() }
        .onChange(of: favoritesOnly) { _, _ in clearSelection() }
        .onChange(of: query) { _, _ in clearSelection() }
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { clearSelection() }
            // `VIBEBUDDY_DEMO_SELECT=<record id>` opens that record once the index
            // lists it (screenshots and QA); a live id never matches a record id.
            if selection == nil, let wanted = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_SELECT"],
               ids.contains(wanted) { selection = wanted; targetMessage = nil }
        }
    }

    /// The strip's search glyph: unfold the list (with the settle spring),
    /// then focus the field once it is in the tree.
    private func unfoldThenFocusSearch() {
        withAnimation(reduceMotion ? nil : .snappy) { listCompact = false }
        DispatchQueue.main.async { searchFocused.wrappedValue = true }
    }

    /// `listLabels` is the lettering at the list's current width (shared
    /// with the live library): the compact strip folds the head to one
    /// search glyph and every row to its agent tile.
    private func sessionList(_ listLabels: ColumnLabelStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // The strip keeps the head's rows in the tree at zero opacity
                // so the pill and the rows below never shift vertically.
                HStack(alignment: .firstTextBaseline) {
                    Text(isSearching ? "Message matches" : favoritesOnly ? "Favorites" : "History")
                        .font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(isSearching ? history.results.count : sessions.count)")
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
                // Under the narrowest full width the head rows keep their
                // one-line layout (clipped at the edge) rather than wrapping
                // and pushing the rows below them down.
                .fixedSize(horizontal: listLabels.transitional, vertical: false)
                .listHeadWords(listLabels)
                // The dashboard's one query; the sidebar's Search row and ⌘F
                // land here while a history library is showing.
                if listLabels.iconOnly {
                    CompactSearchGlyph(action: unfoldThenFocusSearch)
                } else {
                    SearchPill(query: $query, focused: searchFocused)
                }
                if !listLabels.iconOnly, agent == .grokBuild || (isSearching && sessions.contains { !$0.agent.supportsTranscript }) {
                    Text(GrokHistorySource.coverage).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                        .opacity(listLabels.opacity)
                }
                HStack(spacing: 6) {
                    MenuPill(title: agent?.displayName ?? String(localized: "All agents")) {
                        Button("All agents") { agent = nil }
                        ForEach(SessionHistoryAgent.allCases, id: \.self) { value in
                            Button(value.displayName) { agent = value }
                        }
                    }
                    MenuPill(title: archiveTitle) {
                        Button("All history") { archiveScope = "all" }
                        Button("Unarchived") { archiveScope = "unarchived" }
                        Button("Archived") { archiveScope = "archived" }
                    }
                    Spacer(minLength: 4)
                    if history.loading {
                        ProgressView().controlSize(.mini)
                    } else if let date = history.snapshot.refreshedAt {
                        Text(date, style: .time).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                            .help(String(localized: "Updated \(date.formatted(date: .omitted, time: .shortened))"))
                    }
                    MenuPill(title: "···") {
                        Button("Refresh") { Task { await history.refresh() } }
                        Button("Rebuild index") { Task { await history.refresh(rebuild: true) } }
                        if !history.snapshot.issues.isEmpty {
                            Divider()
                            Section("Source notices (\(history.snapshot.issues.count))") {
                                ForEach(history.snapshot.issues, id: \.self) { issue in Text(issue) }
                            }
                        }
                    }
                    .disabled(history.loading)
                }
                .fixedSize(horizontal: listLabels.transitional, vertical: false)
                .listHeadWords(listLabels)
                if let error = history.error {
                    Text(error).font(MacTheme.font(10)).foregroundStyle(MacTheme.status(.error)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .listHeadWords(listLabels)
                }
            }
            .padding(.horizontal, 12).padding(.top, 12)
            // In-flight search chrome has no place on the compact strip.
            if isSearching && history.searching, !listLabels.iconOnly { ProgressView("Searching…").opacity(listLabels.opacity) }
            if isSearching, let error = history.searchError, !listLabels.iconOnly {
                Text("Search could not complete: \(error)").font(MacTheme.font(10)).foregroundStyle(MacTheme.status(.error)).padding(12)
                    .opacity(listLabels.opacity)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    if isSearching {
                        ForEach(history.results) { hit in
                            if let session = sessions.first(where: { $0.id == hit.sessionID }) {
                                Button {
                                    selection = session.id
                                    targetMessage = hit.messageID
                                } label: { HistoryRow(session: session, excerpt: hit.excerpt, active: selection == session.id && targetMessage == hit.messageID) }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        ForEach(sessions) { session in
                            Button { selection = session.id; targetMessage = nil } label: {
                                HistoryRow(session: session, excerpt: nil, active: selection == session.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !history.loading && !(isSearching && history.searching) && (isSearching ? history.results.isEmpty && history.searchError == nil : sessions.isEmpty) {
                        QuietEmptyState(title: isSearching ? "No matching messages" : "No sessions in this view",
                                        message: "Check the project filter and source notices, or refresh the library.",
                                        systemName: "text.magnifyingglass")
                            .padding(.top, 40)
                    }
                }.padding(.horizontal, 8)
            }
            if isSearching && history.results.count == 200, !listLabels.iconOnly {
                Text("Showing the first 200 matches. Narrow your query or project.").font(MacTheme.font(10)).padding(8)
                    .opacity(listLabels.opacity)
            }
        }
    }

    /// The record with its live counterpart, when exactly one live session
    /// carries the same native id in the same checkout (never by title).
    @ViewBuilder private var readingPane: some View {
        if let metadata = selected {
            SessionReaderPane(subject: ReaderSubject(origin: .history,
                                                     live: HistorySessionSupport.liveSession(for: metadata, in: model.sessions),
                                                     record: metadata),
                              targetMessage: targetMessage, model: model, history: history, reader: reader)
        } else {
            QuietEmptyState(title: "Select a conversation", message: "Pick a conversation on the left to read it.",
                            systemName: "text.book.closed")
                .frame(minWidth: DashboardListColumn.readerMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clearSelection() { selection = nil; targetMessage = nil }
}


/// A history row. It has no tile at full width; the compact strip stands
/// the agent's tile in for its words, fading in as they fade out, at the
/// words' own leading origin so it never slides.
private struct HistoryRow: View {
    let session: SessionHistorySession
    var excerpt: String?
    var active: Bool
    @Environment(\.listLabels) private var labels
    /// The words' width at rest, kept so a drag under the narrowest full
    /// width truncates them at the row's edge instead of reflowing.
    @State private var restWordsWidth: CGFloat?

    /// The agent and the date, the row's second line.
    private var byline: String {
        session.agent.displayName + " · " + session.updatedAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Group {
            if labels.iconOnly {
                // The tile is the whole row here, so it carries the words as
                // its tooltip and accessibility text; the branch is inside
                // the row, so its identity (and measured rest width) survives.
                AgentAvatar(agent: session.agent.kind, size: 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(session.title + "\n" + byline)
                    .accessibilityLabel(session.title)
                    .accessibilityValue(byline)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Text(session.title).font(MacTheme.font(13, .medium)).lineLimit(2)
                        if session.isPinned == true { Image(systemName: "pin.fill").foregroundStyle(MacTheme.ink2) }
                        if session.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    }
                    Text(byline).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    if session.isArchived { Label(session.sourceArchived == true ? "Archived in Codex" : "Archived in library", systemImage: "archivebox").font(MacTheme.font(10)) }
                    if let excerpt { Text(excerpt).font(MacTheme.font(10)).lineLimit(3) }
                    if !session.isAvailable { Label("Source unavailable", systemImage: "exclamationmark.triangle").font(MacTheme.font(10)) }
                    else if !session.warnings.isEmpty { Label("Partial or limited record", systemImage: "info.circle").font(MacTheme.font(10)) }
                }
                // Under the narrowest full width the words keep their rest
                // layout and truncate at the row's edge instead of reflowing.
                .frame(width: labels.transitional ? restWordsWidth ?? Self.narrowestWordsWidth : nil, alignment: .leading)
                .opacity(labels.opacity)
                .overlay(alignment: .topLeading) {
                    if labels.transitional {
                        AgentAvatar(agent: session.agent.kind, size: 28).opacity(1 - labels.opacity)
                    }
                }
                // Min 0, or the frame would grow to the frozen block instead of clipping it.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    if !labels.transitional { restWordsWidth = width }
                }
            }
        }
        .padding(10)
        .clipped()
        .background(active ? MacTheme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    /// The words' width at the narrowest full width, for a row first laid
    /// out mid-drag: 240 − 8·2 outer − 10·2 row.
    private static var narrowestWordsWidth: CGFloat { DashboardColumnWidth.list.minFull - 16 - 20 }
}
