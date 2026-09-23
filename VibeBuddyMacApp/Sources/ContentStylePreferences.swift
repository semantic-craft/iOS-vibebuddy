import SwiftUI
import VibeBuddyKit

struct ContentStylePreferences: View {
    @AppStorage(ContentStyleConfiguration.defaultsKey) private var choice = ContentStyleConfiguration.default.style.rawValue
    @AppStorage(ContentStyleConfiguration.customPromptKey) private var customPrompt = ""
    private var style: ContentStyle { ContentStyle(rawValue: choice) ?? ContentStyleConfiguration.default.style }

    private var prompt: Binding<String> {
        Binding(get: { customPrompt }, set: {
            customPrompt = String($0.prefix(ContentStyleConfiguration.maximumCustomPromptCharacters))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ContentStylePicker()
            Text(LocalizedStringKey(style.detail))
                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            Text("All summaries share these content rules. Length follows the purpose: notifications stay short, while complex decisions get more room.")
                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            if style == .custom {
                Text("Custom instructions").font(MacTheme.font(12, .medium))
                TextEditor(text: prompt)
                    .font(MacTheme.font(12))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 100, maxHeight: 180)
                    .background(MacTheme.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MacTheme.ink.opacity(0.12)))
                    .accessibilityLabel("Custom content instructions")
                    .accessibilityIdentifier("customContentPrompt")
                HStack(alignment: .firstTextBaseline) {
                    Text("Describe what to emphasize and how to say it. Facts, unresolved issues and who needs to act are always preserved.")
                        .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(customPrompt.count) / \(ContentStyleConfiguration.maximumCustomPromptCharacters)")
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink2)
                        .accessibilityLabel("Custom instruction character count")
                }
                if customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Enter custom instructions to enable this style.")
                        .font(MacTheme.font(11)).foregroundStyle(MacTheme.status(.requiresInput))
                }
            }
            Text("Changes are saved automatically and apply to the next summary. Current playback continues.")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
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
