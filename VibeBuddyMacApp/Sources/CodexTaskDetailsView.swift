import SwiftUI
import VibeBuddyMacCore

/// Only the selected task is queried. No state or control capability is inferred from these reads.
struct CodexTaskDetailsView: View {
    let threadID: String
    @ObservedObject var model: MenuBarModel
    @State private var goal: Result<CodexTaskGoal?, CodexReadFailure>?
    @State private var terminals: Result<CodexTerminalPage, CodexReadFailure>?
    @State private var fetchedAt: Date?
    @State private var terminalRows: [CodexBackgroundTerminal] = []
    @State private var terminalCursor: String?
    @State private var paging = false
    @State private var expandedTerminals = false
    @State private var refreshingTerminals = false
    @State private var pageError: CodexReadFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex task details").font(MacTheme.font(12, .semibold))
            goalSection
            Divider()
            terminalSection
            if let fetchedAt {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    if context.date.timeIntervalSince(fetchedAt) > 45 {
                        Text("Details may be out of date.").foregroundStyle(MacTheme.status(.requiresInput))
                    } else {
                        Text("Read ") + Text(fetchedAt, style: .relative)
                    }
                }.font(MacTheme.font(10))
            }
        }
        .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
        .textSelection(.enabled)
        .task(id: threadID) {
            goal = nil; terminals = nil; terminalRows = []; terminalCursor = nil; fetchedAt = nil
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    @ViewBuilder private var goalSection: some View {
        Text("Goal").fontWeight(.semibold)
        switch goal {
        case .none: Text("Loading…")
        case .success(.none): Text("No goal reported for this task.")
        case .success(.some(let value)):
            Text(value.objective).foregroundStyle(MacTheme.ink)
            Text(LocalizedStringKey(Self.statusLabel(value.status)))
            Text("Tokens used: \(value.tokensUsed)")
            if let budget = value.tokenBudget { Text("Token budget: \(budget)") }
            Text("Time used: \(value.timeUsedSeconds) seconds")
        case .failure(let failure): Text(LocalizedStringKey(failure.message))
        }
    }

    @ViewBuilder private var terminalSection: some View {
        Text("Background terminals").fontWeight(.semibold)
        switch terminals {
        case .none: Text("Loading…")
        case .failure(let failure): Text(LocalizedStringKey(failure.message))
        case .success:
            if terminalRows.isEmpty { Text("No running background terminals reported.") }
            ForEach(terminalRows) { terminal in
                VStack(alignment: .leading, spacing: 4) {
                    Text(terminal.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(MacTheme.ink)
                    Text(terminal.cwd).font(MacTheme.font(10))
                    HStack {
                        if let pid = terminal.osPid { Text("PID \(pid)") }
                        if let cpu = terminal.cpuPercent { Text("CPU \(cpu, specifier: "%.1f")%") }
                        if let rss = terminal.rssKb { Text("Memory \(rss) KB") }
                    }.font(MacTheme.font(10))
                }
            }
            if terminalCursor != nil {
                Button("Load more terminals") { Task { await loadMoreTerminals() } }
                    .disabled(paging || refreshingTerminals)
            }
            if expandedTerminals {
                Text("Earlier terminal pages are a snapshot. Refresh to read the current list.")
                Button("Refresh terminals") { Task { await refreshTerminals() } }
                    .disabled(paging || refreshingTerminals)
            }
            if let pageError { Text(LocalizedStringKey(pageError.message)) }
        }
    }

    private func refresh() async {
        // Sequential reads avoid two refresh streams racing over pagination state.
        let nextGoal = await model.codexGoal(threadID: threadID)
        guard !Task.isCancelled else { return }
        goal = nextGoal
        guard !paging, !expandedTerminals else { return }
        await refreshTerminals()
    }

    private func refreshTerminals() async {
        guard !paging, !refreshingTerminals else { return }
        refreshingTerminals = true
        defer { refreshingTerminals = false }
        let nextTerminals = await model.codexTerminals(threadID: threadID)
        guard !Task.isCancelled else { return }
        terminals = nextTerminals
        if case .success(let page) = nextTerminals {
            terminalRows = page.data; terminalCursor = page.nextCursor; pageError = nil
        } else {
            terminalRows = []; terminalCursor = nil
        }
        expandedTerminals = false
        if case .success = nextTerminals { fetchedAt = Date() }
    }

    private func loadMoreTerminals() async {
        guard let cursor = terminalCursor, !paging, !refreshingTerminals else { return }
        paging = true
        defer { paging = false }
        let result = await model.codexTerminals(threadID: threadID, cursor: cursor)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let page):
            guard page.nextCursor != cursor else { pageError = .malformed; return }
            var ids = Set(terminalRows.map(\.id))
            terminalRows += page.data.filter { ids.insert($0.id).inserted }
            terminalCursor = page.nextCursor; pageError = nil; expandedTerminals = true
        case .failure(let error): pageError = error
        }
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "active": "Goal active"
        case "paused": "Goal paused"
        case "blocked": "Goal blocked"
        case "usageLimited": "Goal reached usage limit"
        case "budgetLimited": "Goal reached budget limit"
        case "complete": "Goal complete"
        default: "Unknown goal status"
        }
    }
}
