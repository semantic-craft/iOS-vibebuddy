import SwiftUI
import VibeBuddyKit

/// Reading these panels never calls the completion receipt or task control APIs.
struct PhoneTaskDetails: View {
    let session: AgentSession
    let scope: String
    let active: Bool
    @EnvironmentObject private var dashboard: DashboardStore
    @State private var expanded = false
    @State private var goal: TaskReadResponse?
    @State private var terminals: TaskReadResponse?
    @State private var preservesTerminalPages = false
    @State private var failure: String?
    @State private var goalFailure: String?
    @State private var terminalFailure: String?
    @State private var loading = false
    @State private var terminalTask: Task<Void, Never>?
    private var current: Bool { dashboard.readerAuthorityIsCurrent(scope: scope) }
    private var refreshKey: String {
        "\(scope)/\(session.id)/\(dashboard.completionConnectionID)/\(active)/\(expanded)/\(dashboard.state == .connected)/\(current)"
    }
    var body: some View {
        DisclosureGroup("Task goal and background terminals", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Read-only Codex details · token use is budget consumption, not task completion.")
                    .font(.caption).foregroundStyle(.secondary)
                if dashboard.state != .connected { Text("Offline · task details may be out of date.") }
                if loading && goal == nil { ProgressView("Loading task details…") }
                if let failure { Text(taskReadFailureText(failure)).foregroundStyle(.secondary) }
                if let goalFailure { Text(taskReadFailureText(goalFailure)).foregroundStyle(.secondary) }
                if let goal {
                    if let error = goal.failure { Text(taskReadFailureText(error)) }
                    else if let value = goal.goal {
                        Text(value.objective).textSelection(.enabled)
                        Text(goalStatusText(value.status)).font(.caption)
                        Text("Tokens used: \(value.tokensUsed.formatted())")
                        if let budget = value.tokenBudget { Text("Token budget: \(budget.formatted())") }
                        Text(Date(timeIntervalSince1970: Double(value.updatedAt)), style: .relative).font(.caption)
                    } else { Text("No goal has been set for this task.") }
                    Text("Source: Codex app-server").font(.caption).foregroundStyle(.secondary)
                    Text(goal.observedAt, style: .time).font(.caption)
                }
                if let terminalFailure { Text(taskReadFailureText(terminalFailure)).foregroundStyle(.secondary) }
                if let terminals {
                    Text("Background terminals").font(.headline).accessibilityAddTraits(.isHeader)
                    if preservesTerminalPages {
                        Text("Terminal auto-refresh is paused while viewing loaded pages.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(terminals.observedAt, style: .time).font(.caption)
                    Button("Refresh terminal list") {
                        terminalTask?.cancel()
                        terminalTask = Task { await refreshTerminals() }
                    }.disabled(loading || !active || !current || dashboard.state != .connected)
                    if let error = terminals.failure { Text(taskReadFailureText(error)) }
                    else {
                        if terminals.terminals?.isEmpty != false { Text("No background terminals reported.") }
                        ForEach(terminals.terminals ?? []) { terminal in
                            VStack(alignment: .leading) {
                                Text(terminal.command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text(terminal.cwd).font(.caption).foregroundStyle(.secondary)
                                if let cpu = terminal.cpuPercent { Text("CPU: \(cpu.formatted())%") .font(.caption) }
                            }.accessibilityElement(children: .combine)
                        }
                        if terminals.nextCursor != nil {
                            Button("Load more terminals") { terminalTask?.cancel(); terminalTask = Task { await loadTerminals() } }.disabled(loading || !active || !current || dashboard.state != .connected)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
        .task(id: refreshKey) {
            guard active, expanded, current, dashboard.state == .connected else { return }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            } while !Task.isCancelled
        }
        .onDisappear { terminalTask?.cancel() }
        .onChange(of: current) { _, valid in
            if !valid { terminalTask?.cancel(); goal = nil; terminals = nil; preservesTerminalPages = false; goalFailure = nil; terminalFailure = nil; failure = "source_changed" }
        }
        .onChange(of: active) { _, value in if !value { terminalTask?.cancel() } }
        .onChange(of: scope + "/" + session.id) { _, _ in goal = nil; terminals = nil; preservesTerminalPages = false; goalFailure = nil; terminalFailure = nil; failure = nil }
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let capabilities = try await dashboard.taskReadCapabilities(scope: scope)
            guard capabilities.supported.contains(.goal), capabilities.supported.contains(.terminals) else { throw HistoryFailure("unsupported_mac") }
            failure = nil
            async let readGoal = dashboard.taskRead(for: session, scope: scope, kind: .goal)
            // A timer must not discard pages the reader explicitly loaded.
            // Once paged, only the explicit refresh button replaces this window.
            if !preservesTerminalPages {
                do {
                    let result = try await dashboard.taskRead(for: session, scope: scope, kind: .terminals)
                    try Task.checkCancellation()
                    terminals = result; terminalFailure = nil
                } catch {
                    guard !Task.isCancelled else { return }
                    terminalFailure = (error as? HistoryFailure)?.reason ?? "source_unavailable"
                }
            }
            do {
                let result = try await readGoal
                try Task.checkCancellation()
                goal = result; goalFailure = nil
            } catch {
                guard !Task.isCancelled else { return }
                goalFailure = (error as? HistoryFailure)?.reason ?? "source_unavailable"
            }
        } catch {
            guard !Task.isCancelled else { return }
            failure = (error as? HistoryFailure)?.reason ?? "source_unavailable"
        }
    }
    private func refreshTerminals() async {
        guard !loading, active, expanded, current, dashboard.state == .connected else { return }
        loading = true; defer { loading = false }
        do {
            let result = try await dashboard.taskRead(for: session, scope: scope, kind: .terminals)
            try Task.checkCancellation()
            if let reason = result.failure { throw HistoryFailure(reason) }
            terminals = result; preservesTerminalPages = false; terminalFailure = nil
        } catch { if !Task.isCancelled { recordTerminalFailure(error) } }
    }
    private func loadTerminals() async {
        guard let cursor = terminals?.nextCursor, !loading, active, expanded, current,
              dashboard.state == .connected else { return }
        loading = true; defer { loading = false }
        do {
            var result = try await dashboard.taskRead(for: session, scope: scope, kind: .terminals, cursor: cursor)
            try Task.checkCancellation()
            guard active, expanded, current else { return }
            if let reason = result.failure { throw HistoryFailure(reason) }
            let previous = terminals?.terminals ?? []
            let ids = Set(previous.map(\.id))
            result.terminals = previous + (result.terminals ?? []).filter { !ids.contains($0.id) }
            terminals = result; preservesTerminalPages = true; terminalFailure = nil
        } catch { if !Task.isCancelled { recordTerminalFailure(error) } }
    }
    private func recordTerminalFailure(_ error: Error) {
        let reason = (error as? HistoryFailure)?.reason ?? "source_unavailable"
        terminalFailure = reason
        if ["cursor_expired", "cursor_did_not_advance"].contains(reason) {
            terminals?.nextCursor = nil
            preservesTerminalPages = true
        }
    }
}

struct PhoneCodexHistoryView: View {
    let session: AgentSession
    let scope: String
    let newTask: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var fallback = false
    @State private var fallbackReason: String?
    @State private var messages: [HistoryMessage] = []
    @State private var cursor: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var observedAt: Date?
    @State private var attempt = UUID()
    private var current: Bool { dashboard.readerAuthorityIsCurrent(scope: scope) }
    var body: some View {
        Group {
            if fallback {
                VStack(spacing: 0) {
                    Text("Codex service history unavailable · using the local transcript or recent excerpt.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                    if let failure { Text(taskReadFailureText(failure)).font(.caption).foregroundStyle(.secondary) }
                    if fallbackReason != "unsupported_mac" {
                        Button("Retry Codex history") { Task { await load(earlier: false) } }
                            .disabled(loading || !current || dashboard.state != .connected || scenePhase != .active)
                        if loading { ProgressView("Reading transcript…") }
                    }
                    PhoneHistoryView(session: session, scope: scope, newTask: newTask)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            Text("Source: Codex app-server · reading history does not mark a result read.").font(.caption)
                            if let observedAt { Text(observedAt, style: .time).font(.caption) }
                            if !current { Text("The connected source changed. Return to the task list.") }
                            else if dashboard.state != .connected { Text("Offline — showing only pages already loaded on this phone.") }
                            if let failure { Text(taskReadFailureText(failure)).foregroundStyle(.secondary) }
                            if cursor != nil {
                                Button("Load earlier messages") {
                                    let anchor = messages.first?.id
                                    Task { await load(earlier: true); if let anchor { proxy.scrollTo(anchor, anchor: .top) } }
                                }.disabled(loading || !current || dashboard.state != .connected)
                            }
                            if loading { ProgressView("Reading transcript…") }
                            if loaded && messages.isEmpty { Text("No readable messages in this source.") }
                            ForEach(messages) { message in HistoryMessageView(message: message).id(message.id) }
                            Color.clear.frame(height: 1).id("codex-history-bottom")
                        }.padding().frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: loaded) { _, value in if value { proxy.scrollTo("codex-history-bottom", anchor: .bottom) } }
                }
                .navigationTitle("Conversation history")
                .toolbar {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(earlier: false) } }
                        .disabled(loading || !current || dashboard.state != .connected || scenePhase != .active)
                }
            }
        }
        .task(id: "\(scope)/\(session.id)/\(dashboard.completionConnectionID)/\(scenePhase == .active)") {
            guard scenePhase == .active, current, dashboard.state == .connected, !loaded, !fallback else { return }
            await load(earlier: false)
        }
        .onDisappear { attempt = UUID(); loading = false }
        .onChange(of: scenePhase) { _, phase in if phase != .active { attempt = UUID(); loading = false } }
        .onChange(of: current) { _, valid in if !valid { attempt = UUID(); messages = []; cursor = nil; loaded = false } }
    }
    private func load(earlier: Bool) async {
        guard !loading, scenePhase == .active, current else { return }
        let ticket = UUID(); attempt = ticket; loading = true
        defer { if attempt == ticket { loading = false } }
        do {
            let capabilities = try await dashboard.taskReadCapabilities(scope: scope)
            guard capabilities.supported.contains(.history) else { throw HistoryFailure("unsupported_mac") }
            let result = try await dashboard.taskRead(for: session, scope: scope, kind: .history, cursor: earlier ? cursor : nil)
            guard attempt == ticket, !Task.isCancelled, scenePhase == .active else { return }
            if let error = result.failure { throw HistoryFailure(error) }
            guard let incoming = result.messages, Set(incoming.map(\.id)).count == incoming.count else { throw HistoryFailure("invalid_response") }
            if earlier {
                let ids = Set(messages.map(\.id)); messages = incoming.filter { !ids.contains($0.id) } + messages
            } else { messages = incoming }
            cursor = result.nextCursor; observedAt = result.observedAt; loaded = true; failure = nil
            fallback = false; fallbackReason = nil
        } catch {
            guard attempt == ticket, !Task.isCancelled else { return }
            let reason = (error as? HistoryFailure)?.reason ?? "source_unavailable"
            failure = reason
            if !loaded && ["unsupported_mac", "unsupported", "unavailable", "disconnected", "malformed"].contains(reason) {
                fallback = true; fallbackReason = reason
            } else if ["cursor_expired", "cursor_did_not_advance"].contains(reason) { cursor = nil }
        }
    }
}

private func taskReadFailureText(_ reason: String) -> String {
    switch reason {
    case "unsupported_mac": String(localized: "This Mac version does not support task details. Update VibeBuddy on the Mac.")
    case "unsupported": String(localized: "This Codex version does not support this view.")
    case "disconnected": String(localized: "Codex service is not connected.")
    case "cursor_expired", "cursor_did_not_advance": String(localized: "This page is no longer available. Refresh to load the latest data.")
    case "source_changed": String(localized: "The connected source changed. Return to the task list.")
    default: String(localized: "Task details are unavailable. Try again when connected to the Mac.")
    }
}

private func goalStatusText(_ status: String) -> String {
    switch status {
    case "active": String(localized: "Goal active")
    case "paused": String(localized: "Goal paused")
    case "complete", "completed": String(localized: "Goal completed")
    case "blocked": String(localized: "Goal blocked")
    case "budget_limited": String(localized: "Goal budget reached")
    default: String(localized: "Goal status unknown")
    }
}
