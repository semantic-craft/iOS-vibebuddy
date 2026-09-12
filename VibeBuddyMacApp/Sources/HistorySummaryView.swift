import SwiftUI
import VibeBuddyMacCore

struct HistorySummaryView: View {
    @ObservedObject var history: HistoryLibraryModel
    let session: SessionHistorySession
    @State private var expanded = false
    /// The style is a preference, read at generation time; a saved summary keeps the style that wrote it.
    @AppStorage(HistorySummaryStyle.defaultsKey) private var styleChoice = HistorySummaryStyle.default.rawValue
    private var style: HistorySummaryStyle { HistorySummaryStyle(rawValue: styleChoice) ?? .default }
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
                    Picker("Summary style", selection: $styleChoice) {
                        ForEach(HistorySummaryStyle.allCases, id: \.rawValue) { Text(LocalizedStringKey($0.title)).tag($0.rawValue) }
                    }
                    .labelsHidden().fixedSize().help(LocalizedStringKey(style.detail))
                    .accessibilityLabel("Summary style").accessibilityIdentifier("historySummaryStyle")
                    Button(history.summary == nil ? "Generate summary" : "Regenerate") { expanded = true; history.generateSummary() }
                        .disabled(history.reading)
                }
            }
            if let summary = history.summary {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView { HistoryMarkdownView(text: summary.text).padding(.vertical, 8) }.frame(maxHeight: 240)
                } label: {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(summary.style.title))
                        Text("· \(summary.provider) · \(summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }.font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                if !summary.isCurrent(for: session) { Text("Out of date — the conversation has changed. Regenerate to update.").font(MacTheme.font(10)).foregroundStyle(.orange) }
                if expanded { Text(summary.coverage).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2) }
            } else {
                Text("On request, sends readable dialogue to \(provider). Injected context and thinking are excluded.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                Text(LocalizedStringKey(style.detail)).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            }
            if let error = history.summaryError { Text(error).font(MacTheme.font(10)).foregroundStyle(.red) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }
}
