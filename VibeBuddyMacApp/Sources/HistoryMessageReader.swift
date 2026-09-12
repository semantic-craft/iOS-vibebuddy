import AppKit
import SwiftUI
import VibeBuddyMacCore

struct HistoryMessageReader: View {
    let session: SessionHistorySession
    let targetMessage: String?
    @State private var rows: [HistoryMessageRow] = []
    @State private var toolsOpen = Set<String>()
    @State private var thinkingOpen = Set<String>()
    @State private var pageStart = 0
    private let pageSize = 30
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 1).id("page-top")
                    if pageStart > 0 {
                        Button("Earlier messages") { pageStart = max(0, pageStart - pageSize); proxy.scrollTo("page-top", anchor: .top) }
                    }
                    if !rows.isEmpty {
                        Text("Messages \(pageStart + 1)–\(min(pageStart + pageSize, rows.count)) of \(rows.count)")
                            .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                    if let targetMessage, !rows.contains(where: { $0.contains(targetMessage) }) {
                        Text("This match is no longer in the current record. Search again.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                    ForEach(Array(rows.dropFirst(pageStart).prefix(pageSize))) { row in
                        message(row).padding(10)
                            .background(row.contains(targetMessage) ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                            .id(row.id)
                    }
                    if pageStart + pageSize < rows.count {
                        Button("Later messages") { pageStart += pageSize; proxy.scrollTo("page-top", anchor: .top) }
                    }
                    if rows.isEmpty { Text("No dialogue to display.").foregroundStyle(MacTheme.ink2) }
                }.padding(16)
            }
            .task(id: "\(session.sourceRevision ?? "")|\(session.messages.count)|\(targetMessage ?? "")") {
                let messages = session.messages, target = targetMessage
                let projected = await Task.detached(priority: .userInitiated) { SessionHistoryPresentation.rows(messages, revealing: target) }.value
                guard !Task.isCancelled else { return }
                rows = projected
                if let index = rows.firstIndex(where: { $0.contains(target) }) {
                    pageStart = index
                    toolsOpen.insert(rows[index].id); thinkingOpen.insert(rows[index].id)
                    await Task.yield()
                    proxy.scrollTo(rows[index].id, anchor: .top)
                } else { pageStart = min(pageStart, max(0, rows.count - 1)) }
            }
        }
    }
    @ViewBuilder private func message(_ row: HistoryMessageRow) -> some View {
        if row.kind == .compactSummary {
            Text("Context compacted").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(.quaternary, in: Capsule()).frame(maxWidth: .infinity)
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
                                    HStack { Text(tool.name).fontWeight(.medium); if tool.isError { Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(.red) } }
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
                            if failures > 0 { Text("\(failures) failed").foregroundStyle(.red) }
                        }.font(MacTheme.font(10))
                    }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
