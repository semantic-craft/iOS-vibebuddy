import SwiftUI
import VibeBuddyMacCore

struct HistorySummaryView: View {
    @ObservedObject var history: HistoryLibraryModel
    let session: SessionHistorySession
    @State private var expanded = false
    private var provider: String { CompletionSummaryConfiguration.load().provider?.display ?? "configured provider" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Conversation summary").font(MacTheme.font(13, .semibold))
                if history.summarizing {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { history.cancelSummary() }
                } else {
                    Spacer()
                    Button(history.summary == nil ? "Generate summary" : "Regenerate") { expanded = true; history.generateSummary() }
                        .disabled(history.reading)
                }
            }
            if let summary = history.summary {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView { HistoryMarkdownView(text: summary.text).padding(.vertical, 8) }.frame(maxHeight: 240)
                } label: {
                    Text("\(summary.provider) · \(summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                if !summary.isCurrent(for: session) { Text("Out of date — the conversation has changed. Regenerate to update.").font(MacTheme.font(10)).foregroundStyle(.orange) }
                if expanded { Text(summary.coverage).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2) }
            } else {
                Text("On request, sends readable dialogue to \(provider). Injected context and thinking are excluded.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            }
            if let error = history.summaryError { Text(error).font(MacTheme.font(10)).foregroundStyle(.red) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
