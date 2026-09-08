import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// Separate consent and text model, alongside the existing provider's shared credentials.
struct CompletionSummarySettingsSection: View {
    let provider: VoiceProvider
    let hasKey: Bool
    let apiKey: String
    @ObservedObject var tests: SettingsTestCoordinator
    let canTest: Bool
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var enabled = false
    @AppStorage private var modelID: String
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    init(provider: VoiceProvider, hasKey: Bool, apiKey: String, tests: SettingsTestCoordinator, canTest: Bool) {
        self.provider = provider
        self.hasKey = hasKey
        self.apiKey = apiKey
        self.tests = tests
        self.canTest = canTest
        _modelID = AppStorage(wrappedValue: CompletionSummaryConfiguration.recommendedModel(provider), CompletionSummaryConfiguration.modelKey(provider))
    }

    /// Match the runtime load policy without writing defaults while browsing.
    static func effectiveModelID(_ stored: String, provider: VoiceProvider) -> String {
        stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CompletionSummaryConfiguration.recommendedModel(provider) : stored
    }

    private var configuration: CompletionSummaryConfiguration {
        // An explicit sample test is independent of enabling automatic summaries.
        .init(enabled: true, provider: provider, modelID: Self.effectiveModelID(modelID, provider: provider),
              language: VoiceLanguage(rawValue: language) ?? .english,
              qwenUseIntl: intl, qwenWorkspaceID: workspace)
    }

    private var configurationFailure: CompletionSummaryFailure? {
        configuration.configurationFailure ?? (hasKey ? nil : .missingKey)
    }

    var body: some View {
        Section {
            Toggle("AI completion summaries", isOn: $enabled)
                .accessibilityIdentifier("completionSummaryEnabled")
            Text("Send followed tasks’ final results to the selected provider. Summaries may appear in notification previews. This does not enable the microphone.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Provider", value: provider.display)
            VStack(alignment: .leading, spacing: 4) {
                Text("Text model ID").font(.caption).foregroundStyle(.secondary)
                TextField("Text model ID", text: $modelID,
                          prompt: CompletionSummaryConfiguration.recommendedModel(provider).isEmpty
                            ? Text("Enter a text model available to your account")
                            : Text(verbatim: CompletionSummaryConfiguration.recommendedModel(provider)))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("completionSummaryModelID")
                if !CompletionSummaryConfiguration.recommendedModel(provider).isEmpty {
                    Text("Leave the text model blank to use the recommended default.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Saved separately for each provider. This text model is independent of the voice conversation’s realtime model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = configurationFailure {
                Label(failureMessage(failure), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Configuration entered — model access is confirmed only by a successful test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Test with sample", action: test)
                .disabled(tests.isBusy || configurationFailure != nil || !canTest)
                .accessibilityIdentifier("completionSummaryTest")
            Text("Testing sends one synthetic result using this Mac’s saved API key and may incur a text-generation charge. It does not send your task history or post a notification.")
                .font(.caption).foregroundStyle(.secondary)
            SettingsTestFeedback(tests: tests, purpose: .summary)
        } header: {
            Text("AI completion summaries")
        } footer: {
            Text("Followed task completions use one summary when enabled. If generation fails, the ordinary completion notification is used.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: configuration) { _, _ in tests.invalidate() }
        .onChange(of: hasKey) { _, _ in tests.invalidate() }
        .onChange(of: enabled) { _, _ in tests.invalidate() }
        .onDisappear { tests.invalidate() }
    }

    private func test() {
        guard !tests.isBusy, configurationFailure == nil, canTest else { return }
        let config = configuration
        let key = apiKey
        tests.start(.summary, timeout: .seconds(13), operation: {
            await SettingsModelTestOperations.summary(configuration: config, apiKey: key)
        })
    }

    private func failureMessage(_ failure: CompletionSummaryFailure) -> LocalizedStringKey {
        LocalizedStringKey(SettingsModelTestOperations.summaryFailureMessage(failure))
    }
}
