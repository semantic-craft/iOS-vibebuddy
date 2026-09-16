import SwiftUI
import VibeBuddyKit

struct PhoneHistoryView: View {
    let session: AgentSession
    let scope: String
    let newTask: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore
    @State private var viewportHeight: CGFloat = 0
    @State private var messageFrames: [String: CGRect] = [:]
    @State private var prependAnchor: (id: String, frame: CGRect)?
    @StateObject private var reader = PhoneHistoryReader()
    private var supported: Bool { HistoryIdentity.transcriptKey(for: session) != nil }
    private var current: Bool { dashboard.readerAuthorityIsCurrent(scope: scope) }
    private var connected: Bool { dashboard.state == .connected }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Historical transcript · live task status remains on the task page. Reading here does not mark a result read.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !current {
                        Text("The connected source changed. Return to the task list.")
                    } else if !supported {
                        Text("Recent excerpt only — this agent has no supported local transcript reader.")
                        RecentOutputCard(output: dashboard.recentOutputs[session.id])
                    } else {
                        if !connected {
                            Text(reader.messages.isEmpty ? "Offline. Connect to the Mac to read history." : "Offline — showing only pages already loaded on this phone.")
                                .accessibilityIdentifier("phone-history-offline")
                        }
                        Text("Thinking and metadata are not included. Tool records can be expanded.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let page = reader.page {
                            if page.sourceLimitReached {
                                Text("Only the first 32 MiB was read. Later content is not loaded; this is not the latest page of the full source.")
                                    .foregroundStyle(.orange).accessibilityIdentifier("phone-history-partial")
                            }
                            ForEach(Array(page.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Loaded \(reader.messages.count) of \(page.totalMessages) readable messages")
                                .font(.caption).accessibilityIdentifier("phone-history-count")
                        }
                        if reader.chainInvalid && reader.pending == nil {
                            Text("This paging chain expired or changed. Loaded text is retained until you choose the updated transcript.")
                        }
                        if let failure = reader.failure {
                            Text(failureText(failure)).foregroundStyle(.secondary)
                                .accessibilityIdentifier("phone-history-error")
                        }
                        if ["session_not_found", "identity_mismatch", "ambiguous_source", "source_unavailable"].contains(reader.failure ?? "") {
                            Text("Recent excerpt only — the exact historical source is unavailable.").font(.caption)
                            RecentOutputCard(output: dashboard.recentOutputs[session.id])
                        }
                        if reader.loading && reader.page == nil { ProgressView("Reading transcript…") }
                        if reader.page != nil && reader.messages.isEmpty { Text("No readable messages in this source.") }
                        ForEach(reader.messages) { message in
                            VStack(spacing: 0) {
                                Color.clear.frame(height: 0).id("history-anchor-" + message.id)
                                HistoryMessageView(message: message)
                            }.id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: HistoryMessageFrames.self,
                                        value: [message.id: geometry.frame(in: .named("historyViewport"))])
                                })
                        }
                        Color.clear.frame(height: 1).id("history-bottom")

                    }
                }.scrollTargetLayout().padding().frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "historyViewport")
            .onAppear { viewportHeight = viewport.size.height }
            .onChange(of: viewport.size.height) { _, height in viewportHeight = height }
            .onPreferenceChange(HistoryMessageFrames.self) { messageFrames = $0 }
            .onChange(of: reader.prependRevision) { _, _ in
                guard let anchor = prependAnchor else { return }
                let gap = viewport.size.height - anchor.frame.height
                let target = abs(gap) > 1 ? anchor.id : "history-anchor-" + anchor.id
                let alignment = anchor.frame.minY / (abs(gap) > 1 ? gap : max(1, viewport.size.height))
                // The prepended rows must enter layout before resolving their target geometry.
                DispatchQueue.main.async {
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: alignment)) }
                }
            }
            .onChange(of: reader.scrollRevision) { _, _ in
                if let target = reader.scrollTarget { proxy.scrollTo(target, anchor: reader.scrollToTop ? .top : .bottom) }
            }
        }
        }
        .safeAreaInset(edge: .bottom) {
            if supported && current {
                VStack(spacing: 6) {
                    Text(connected ? "\(reader.messages.count) messages loaded" : "Offline — loaded pages retained")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("phone-history-loaded-status")
                    HStack {
                    if reader.loading { ProgressView().controlSize(.small) }
                    if reader.hasEarlier {
                        Button("Load earlier") { load(earlier: true) }.accessibilityIdentifier("phone-history-earlier")
                    }
                    Spacer()
                    if reader.pending != nil {
                        Button("View updated transcript") { reader.showPending() }.accessibilityIdentifier("phone-history-bottom-update")
                    } else {
                        Button(reader.chainInvalid ? "Load updated page" : "Check for updates") { load() }
                            .accessibilityIdentifier("phone-history-refresh")
                    }
                    }
                }.padding().background(.regularMaterial).disabled(reader.loading || !connected)
            }
        }
        .navigationTitle("Conversation history")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New task", systemImage: "plus", action: newTask) } }
        .task {
            guard current else { return }
            if supported { load() } else { await dashboard.loadRecentOutput(session.id) }
        }
        .onChange(of: reader.failure) { _, reason in
            if current, reason != nil {
                Task { await dashboard.loadRecentOutput(session.id) }
            }
        }
        .onDisappear { reader.cancel() }
        .onChange(of: current) { _, value in if !value { reader.cancel(clear: true) } }
        .onChange(of: connected) { _, value in if !value { reader.cancel() } }
    }

    private func load(earlier: Bool = false) {
        reader.load(earlier: earlier, beforePrepend: {
            // Capture at receipt, not at tap: the person can scroll while the Mac reads.
            prependAnchor = nil
            let visible = messageFrames.filter { $0.value.maxY > 0 && $0.value.minY < viewportHeight }.sorted { $0.value.minY < $1.value.minY }
            if let first = visible.first(where: { $0.value.minY >= 0 }) ?? visible.first { prependAnchor = (first.key, first.value) }
        }) { cursor in
            try await dashboard.history(for: session, scope: scope, cursor: cursor)
        }
    }
    private func failureText(_ reason: String) -> String {
        switch reason {
        case "reader_busy": "The Mac is reading another transcript. Try again shortly."
        case "revision_changed", "cursor_expired": "The source or paging position changed. Load an updated page."
        case "session_not_found": "This exact session could not be located on the Mac."
        case "identity_mismatch", "ambiguous_source": "The source identity could not be verified."
        case "message_exceeds_budget": "A message exceeds the reading limit."
        case "unauthorized": "Reconnect to the Mac to restore access."
        default: "The transcript is unavailable. Reconnect or retry."
        }
    }
}

private struct HistoryMessageView: View {
    let message: HistoryMessage
    private var tool: Bool { message.role == "tool" || message.toolName != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if tool {
                DisclosureGroup(message.toolName ?? "Tool result") { text }
                    .accessibilityIdentifier("phone-history-tool-" + message.id)
            } else { text }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("phone-history-message-" + message.id)
    }
    private var codeBlocks: [String] {
        message.text.components(separatedBy: "```").enumerated().compactMap { index, block in
            guard index % 2 == 1, let newline = block.firstIndex(of: "\n") else { return nil }
            return String(block[block.index(after: newline)...])
        }
    }
    private var text: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(codeBlocks.enumerated()), id: \.offset) { index, code in
                Button("Copy code \(index + 1)") { UIPasteboard.general.string = code }.font(.caption)
            }
            Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                .accessibilityIdentifier("phone-history-copy-" + message.id)
                .font(.caption)
            Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HistoryMessageFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
