import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct HistorySummaryView: View {
    @ObservedObject var history: HistoryLibraryModel
    let session: SessionHistorySession
    @State private var expanded = false
    @AppStorage(ContentStyleConfiguration.defaultsKey) private var styleChoice = ContentStyleConfiguration.default.style.rawValue
    @AppStorage(ContentStyleConfiguration.customPromptKey) private var customPrompt = ""
    private var contentStyle: ContentStyleConfiguration {
        _ = styleChoice
        _ = customPrompt
        return ContentStyleConfiguration.load()
    }
    private var provider: String { CompletionSummaryConfiguration.load().provider?.display ?? "configured provider" }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conversation summary").font(MacTheme.font(13, .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ContentStylePicker().fixedSize()
                    Spacer(minLength: 4)
                    generateButton.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    ContentStylePicker()
                    generateButton
                }
            }
            Text("Changes apply to all summary entries. Saved summaries keep their original style.")
                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            if !contentStyle.isValid {
                Text("Enter custom instructions in Settings before generating a summary.")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.status(.requiresInput))
            }
            if let summary = history.summary {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView { HistoryMarkdownView(text: summary.text).padding(.vertical, 8) }.frame(maxHeight: 240)
                } label: {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(summary.contentStyle?.style.title ?? summary.style.title))
                        Text("· \(summary.provider) · \(summary.model) · \(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    }.font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                if !summary.isCurrent(for: session) { Text("Out of date — the conversation has changed. Regenerate to update.").font(MacTheme.font(10)).foregroundStyle(MacTheme.status(.requiresInput)) }
                if summary.contentStyle != contentStyle {
                    Text("This summary uses a different content style. Regenerate to apply the current settings.")
                        .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                if expanded { Text(summary.coverage).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2) }
            } else {
                Text("On request, sends readable dialogue to \(provider). Injected context and thinking are excluded.").font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                Text(LocalizedStringKey(contentStyle.style.detail)).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
            }
            if let error = history.summaryError { Text(error).font(MacTheme.font(10)).foregroundStyle(MacTheme.status(.error)) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var generateButton: some View {
        if history.summarizing {
            HStack {
                ProgressView().controlSize(.mini)
                Button("Cancel") { history.cancelSummary() }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            }
        } else {
            Button(history.summary == nil ? "Generate summary" : "Regenerate") {
                expanded = true
                history.generateSummary()
            }
            .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            .disabled(history.reading || !contentStyle.isValid)
        }
    }
}

struct ContentStylePicker: View {
    @AppStorage(ContentStyleConfiguration.defaultsKey) private var choice = ContentStyleConfiguration.default.style.rawValue
    private var style: ContentStyle { ContentStyle(rawValue: choice) ?? ContentStyleConfiguration.default.style }

    var body: some View {
        HStack(spacing: 8) {
            Text("Content style").font(MacTheme.font(12, .medium))
            MenuPill(title: String(localized: String.LocalizationValue(style.title))) {
                ForEach(ContentStyle.allCases, id: \.rawValue) { item in
                    Button { choice = item.rawValue } label: {
                        if item == style {
                            Label(LocalizedStringKey(item.title), systemImage: "checkmark")
                        } else {
                            Text(LocalizedStringKey(item.title))
                        }
                    }
                }
            }
            .help(LocalizedStringKey(style.detail))
            .accessibilityLabel("Content style")
            .accessibilityValue(LocalizedStringKey(style.title))
            .accessibilityIdentifier("contentStyle")
        }
    }
}
