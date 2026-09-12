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
                Text("Conversation summary").font(.headline)
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
                    Text("\(summary.provider) · \(summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                if !summary.isCurrent(for: session) { Text("Out of date — the conversation has changed. Regenerate to update.").font(.caption).foregroundStyle(.orange) }
                if expanded { Text(summary.coverage).font(.caption2).foregroundStyle(.secondary) }
            } else {
                Text("On request, sends readable dialogue to \(provider). Injected context and thinking are excluded.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = history.summaryError { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
