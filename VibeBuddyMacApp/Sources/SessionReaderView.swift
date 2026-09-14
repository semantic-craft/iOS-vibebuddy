import AppKit
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The conversation body shared by the live and history readers (ADR-0024):
/// user bubbles, assistant Markdown, tool and thinking rows folded, the
/// compaction marker. It opens on the newest page and walks backwards on
/// request; new rows follow the reader only while they are at the bottom,
/// otherwise a small pill counts them until the reader asks to catch up.
/// Reading here never confirms a result; only the `tail` (the result card)
/// carries that semantics.
struct SessionReaderView<Header: View, Tail: View>: View {
    let rows: [HistoryMessageRow]
    /// A search hit to reveal, if the reader came from a match.
    let targetMessage: String?
    /// One line above the first visible row (the excerpt notice, say); nil for none.
    let note: String?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let tail: () -> Tail

    @State private var window = ReaderWindow(start: 0, count: 0)
    @State private var revealedTarget: String?
    @State private var shownIDs: [String] = []
    /// Only an actual user scroll opts out. Layout growth must not be
    /// mistaken for scrolling away from the latest message.
    @State private var following = true
    @State private var unseen = 0
    @State private var toolsOpen = Set<String>()
    @State private var thinkingOpen = Set<String>()
    @State private var scrollHeight: CGFloat = 0

    private static var bottomID: String { "reader-bottom" }
    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header()
                        if window.hasEarlier {
                            Button("Earlier messages · \(window.start) more") { showEarlier(proxy) }
                                .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                                .accessibilityLabel("Show earlier messages")
                        } else if !rows.isEmpty {
                            Text("Start of the readable transcript").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink3)
                        }
                        if let note {
                            Text(note).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                        }
                        if let targetMessage, !rows.contains(where: { $0.contains(targetMessage) }) {
                            Text("This match is no longer in the current record. Search again.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                        }
                        // Rows can shrink before onChange updates the saved window.
                        ForEach(rows[window.grown(to: rows.count).range]) { row in
                            message(row).padding(10)
                                .background(row.contains(targetMessage) ? MacTheme.ink.opacity(0.07) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .id(row.id)
                        }
                        if rows.isEmpty { Text("No dialogue to display.").foregroundStyle(MacTheme.ink2) }
                        tail()
                        Color.clear.frame(height: 1).id(Self.bottomID)
                            .background(GeometryReader { geometry in
                                Color.clear.preference(key: BottomOffsetKey.self,
                                                       value: geometry.frame(in: .named("reader")).minY)
                            })
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(ReaderScrollObserver { atBottom in
                        following = atBottom
                        if atBottom { unseen = 0 }
                    })
                }
                .coordinateSpace(name: "reader")
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ScrollHeightKey.self, value: geometry.size.height)
                })
                .onPreferenceChange(ScrollHeightKey.self) { scrollHeight = $0 }
                .onPreferenceChange(BottomOffsetKey.self) { offset in
                    // Within a line of the sentinel counts as "at the bottom".
                    let bottom = offset <= scrollHeight + 24
                    if bottom {
                        following = true
                        unseen = 0
                    } else if following {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
                if unseen > 0 && !following {
                    Button {
                        unseen = 0
                        following = true
                        withAnimation(.smooth(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    } label: {
                        Label(unseen == 1 ? String(localized: "1 new message") : String(localized: "\(unseen) new messages"),
                              systemImage: "arrow.down")
                            .font(MacTheme.font(10.5, .semibold))
                    }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.ink), size: .small))
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
            .onAppear { place(rows.map(\.id), proxy: proxy, initial: true) }
            .onChange(of: rows.map(\.id)) { _, ids in place(ids, proxy: proxy, initial: false) }
            .onChange(of: targetMessage) { _, _ in
                revealedTarget = nil
                place(rows.map(\.id), proxy: proxy, initial: true)
            }
        }
    }

    /// Decide what to show and where to rest after the rows changed.
    private func place(_ ids: [String], proxy: ScrollViewProxy, initial: Bool) {
        defer { shownIDs = ids }
        if let targetMessage, targetMessage != revealedTarget,
           let index = rows.firstIndex(where: { $0.contains(targetMessage) }) {
            revealedTarget = targetMessage
            following = false
            window = .revealing(index, of: ids.count)
            let id = rows[index].id
            toolsOpen.insert(id); thinkingOpen.insert(id)
            Task { await Task.yield(); proxy.scrollTo(id, anchor: .top) }
            return
        }
        if !initial, let appended = ReaderWindow.appendedCount(old: shownIDs, new: ids) {
            window = window.grown(to: ids.count)
            guard appended > 0 else { return }
            if following {
                Task { await Task.yield(); proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            } else {
                unseen += appended
            }
            return
        }
        window = .tail(of: ids.count)
        unseen = 0
        following = true
        Task { await Task.yield(); proxy.scrollTo(Self.bottomID, anchor: .bottom) }
    }

    private func showEarlier(_ proxy: ScrollViewProxy) {
        guard window.start < rows.count else { return }
        let keep = rows[window.start].id
        following = false
        window = window.expandedEarlier()
        // The rows above grow the content; keep the row the reader was looking at where it was.
        Task { await Task.yield(); proxy.scrollTo(keep, anchor: .top) }
    }

    @ViewBuilder private func message(_ row: HistoryMessageRow) -> some View {
        if row.kind == .compactSummary {
            Text("Context compacted").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(MacTheme.bg2, in: Capsule()).overlay(Capsule().strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline)).frame(maxWidth: .infinity)
        } else if row.kind == .meta {
            DisclosureGroup("Injected context · search match", isExpanded: .constant(true)) {
                Text(row.text).font(MacTheme.font(10)).textSelection(.enabled)
            }
        } else if row.role == .system {
            Text(row.text).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2).frame(maxWidth: .infinity)
        } else if row.role == .user {
            HStack {
                Spacer(minLength: 30)
                HistoryMarkdownView(text: row.text).padding(14).frame(maxWidth: 540)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if !row.thinking.isEmpty {
                    DisclosureGroup(isExpanded: binding(row.id, in: $thinkingOpen)) {
                        Text(row.thinking).font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2).textSelection(.enabled)
                    } label: {
                        HStack {
                            Text("Thinking").font(MacTheme.font(10, .medium))
                            if !thinkingOpen.contains(row.id) { Text(row.thinking.replacingOccurrences(of: "\n", with: " ")).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2).lineLimit(1) }
                        }
                    }
                }
                if !row.text.isEmpty {
                    HistoryMarkdownView(text: row.text)
                    Button("Copy message") { copy(row.text) }.font(MacTheme.font(10)).buttonStyle(.borderless)
                }
                if !row.tools.isEmpty {
                    DisclosureGroup(isExpanded: binding(row.id, in: $toolsOpen)) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(row.tools) { tool in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack { Text(tool.name).fontWeight(.medium); if tool.isError { Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(MacTheme.status(.error)) } }
                                    if !tool.input.isEmpty { toolSection("Input", text: tool.input) }
                                    if let output = tool.output { toolSection("Output", text: output) }
                                }
                                if tool.id != row.tools.last?.id { Divider() }
                            }
                        }.padding(.top, 8)
                    } label: {
                        HStack(spacing: 8) {
                            Text(row.tools.count == 1 ? row.tools[0].name : "\(row.tools.count) tool calls").fontWeight(.medium)
                            Text(row.tools.count == 1 ? row.tools[0].preview : row.tools.map(\.name).joined(separator: " · ")).lineLimit(1).foregroundStyle(MacTheme.ink2)
                            let failures = row.tools.filter(\.isError).count
                            if failures > 0 { Text("\(failures) failed").foregroundStyle(MacTheme.status(.error)) }
                        }.font(MacTheme.font(10))
                    }.padding(10).background(MacTheme.bg2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func toolSection(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                Spacer()
                Button("Copy \(label.lowercased())") { copy(text) }.font(MacTheme.font(10))
            }
            Text(String(text.prefix(600))).font(MacTheme.mono(10)).textSelection(.enabled)
            if text.count > 600 { Text("Preview · \(text.count) characters. Copy to read all indexed text.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2) }
        }
    }

    private func binding(_ id: String, in values: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { if $0 { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) } })
    }

    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct BottomOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct ScrollHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// AppKit distinguishes user scrolls from programmatic scrolling and layout
/// changes, including legacy wheels that have no begin/end gesture pair.
/// Scoped to the enclosing conversation scroll view, never other app windows.
private struct ReaderScrollObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> ObserverView { ObserverView(changed: changed) }
    func updateNSView(_ view: ObserverView, context: Context) { view.changed = changed; view.observe() }
    static func dismantleNSView(_ view: ObserverView, coordinator: ()) { view.detach() }

    final class ObserverView: NSView {
        var changed: (Bool) -> Void
        private weak var observed: NSScrollView?
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observe() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observe() }
        func observe() {
            guard let scroll = enclosingScrollView, observed !== scroll else { return }
            detach()
            observed = scroll
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(started), name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrolled), name: NSScrollView.didLiveScrollNotification, object: scroll)
            center.addObserver(self, selector: #selector(scrolled), name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        func detach() { NotificationCenter.default.removeObserver(self); observed = nil }
        @objc private func started() { changed(false) }
        @objc private func scrolled() {
            guard let scroll = observed, let document = scroll.documentView else { return }
            let visible = scroll.documentVisibleRect
            let bottom = document.isFlipped
                ? document.bounds.maxY - visible.maxY <= 24
                : visible.minY - document.bounds.minY <= 24
            changed(bottom)
        }
    }
}
