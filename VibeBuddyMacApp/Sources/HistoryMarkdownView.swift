import AppKit
import SwiftUI
import VibeBuddyMacCore

struct HistoryMarkdownView: View {
    let text: String
    @State private var blocks: [HistoryMarkdownBlock] = []
    var body: some View {
        HistoryMarkdownBlocks(blocks: blocks)
            .task(id: text) {
                let input = text
                let parsed = await Task.detached(priority: .userInitiated) { SessionHistoryMarkdown.parse(input) }.value
                guard !Task.isCancelled else { return }
                blocks = parsed
            }
    }
}
private struct HistoryMarkdownBlocks: View {
    let blocks: [HistoryMarkdownBlock]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in render(blocks[index]) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
    @ViewBuilder private func render(_ block: HistoryMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text): inline(text).textSelection(.enabled)
        case .heading(let level, let text): inline(text).font(level == 1 ? MacTheme.font(17, .semibold) : level == 2 ? MacTheme.font(15, .semibold) : MacTheme.font(13, .semibold)).textSelection(.enabled)
        case .code(let language, let code):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(language.isEmpty ? "Code" : language).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    Spacer()
                    Button("Copy code") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }.font(MacTheme.font(10))
                }
                ScrollView(.horizontal) { Text(code).font(MacTheme.mono(12)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }
            }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        case .quote(let children):
            HStack(alignment: .top) {
                Rectangle().fill(MacTheme.line).frame(width: 3)
                AnyView(HistoryMarkdownBlocks(blocks: children)).foregroundStyle(MacTheme.ink2)
            }.fixedSize(horizontal: false, vertical: true)
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text(start.map { "\($0 + index)." } ?? "•").foregroundStyle(MacTheme.ink2)
                        AnyView(HistoryMarkdownBlocks(blocks: items[index]))
                    }
                }
            }
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                inline(rows[row][column]).fontWeight(row == 0 ? .semibold : .regular).textSelection(.enabled).frame(maxWidth: 280, alignment: .leading)
                            }
                        }
                        if row == 0 { Divider() }
                    }
                }.padding(10)
            }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        case .rule: Divider()
        }
    }
}
