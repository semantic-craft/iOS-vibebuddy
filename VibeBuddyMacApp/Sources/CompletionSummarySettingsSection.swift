import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// Separate consent and text model, alongside the existing provider's shared credentials.
struct CompletionSummarySettingsSection: View {
    let provider: VoiceProvider
    let hasKey: Bool
    let credentialRevision: Int
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var enabled = false
    @AppStorage private var modelID: String
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    @State private var testTask: Task<Void, Never>?
    @State private var testing = false
    @State private var result: CompletionSummaryResult?

    init(provider: VoiceProvider, hasKey: Bool, credentialRevision: Int = 0) {
        self.provider = provider
        self.hasKey = hasKey
        self.credentialRevision = credentialRevision
        _modelID = AppStorage(wrappedValue: "", CompletionSummaryConfiguration.modelKey(provider))
    }

    private var configuration: CompletionSummaryConfiguration {
        // An explicit sample test is independent of enabling automatic summaries.
        .init(enabled: true, provider: provider, modelID: modelID,
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
                TextField("Enter a text model available to your account", text: $modelID)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("completionSummaryModelID")
                Text("Saved separately for each provider. Use a text model, not the realtime model above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = configurationFailure {
                Label(failureMessage(failure), systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Configuration entered — model access is confirmed only by a successful test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Test with sample", action: test)
                    .disabled(testing || configurationFailure != nil)
                    .accessibilityIdentifier("completionSummaryTest")
                if testing {
                    ProgressView().controlSize(.small)
                    Button("Cancel", action: cancelTest)
                }
            }
            Text("Testing sends one synthetic result using this Mac’s saved API key and may incur a text-generation charge. It does not send your task history or post a notification.")
                .font(.caption).foregroundStyle(.secondary)
            if let result {
                if let failure = result.failure {
                    Label(failureMessage(failure), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let text = result.text {
                    Label("Sample generated", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(text).textSelection(.enabled)
                        .accessibilityIdentifier("completionSummaryTestResult")
                    Text("Check that the summary still says device verification is pending.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Elapsed: \(String(format: "%.2f", result.completionLatency)) s")
                    .font(.caption).foregroundStyle(.secondary)
                if let usage = result.usage {
                    Text("Tokens — input: \(usage.inputTokens.map(String.init) ?? "—"), output: \(usage.outputTokens.map(String.init) ?? "—"), total: \(usage.totalTokens.map(String.init) ?? "—")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("AI completion summaries")
        } footer: {
            Text("Automatic completion notifications are not connected in this build. You can save these settings and test a sample.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: configuration) { _, _ in invalidateTest() }
        .onChange(of: hasKey) { _, _ in invalidateTest() }
        .onChange(of: credentialRevision) { _, _ in invalidateTest() }
        .onChange(of: enabled) { _, _ in invalidateTest() }
        .onDisappear { invalidateTest() }
    }

    private func test() {
        guard !testing, configurationFailure == nil else { return }
        result = nil
        testing = true
        let config = configuration
        testTask = Task { @MainActor in
            let now = Date()
            let input = CompletionSummaryInput(sourceID: "settings-sample", sessionID: UUID().uuidString,
                completionID: UUID().uuidString, title: "Sample routing fix",
                finalText: "Fixed duplicate routing. Unit tests passed. Real-device verification is still pending; this result does not claim deployment or device acceptance.",
                completedAt: now, observedAt: now)
            let response = await CompletionSummaryService().generate(input, configuration: config)
            guard !Task.isCancelled else { return }
            result = response
            testing = false
            testTask = nil
        }
    }

    private func cancelTest() {
        testTask?.cancel()
        testTask = nil
        testing = false
    }

    private func invalidateTest() {
        cancelTest()
        result = nil
    }

    private func failureMessage(_ failure: CompletionSummaryFailure) -> LocalizedStringKey {
        switch failure {
        case .missingModel: "Enter a text model ID to test summaries."
        case .missingKey: "Add this provider’s API key above."
        case .invalidModel: "The text model ID contains unsupported characters."
        case .invalidWorkspace: "Check the Qwen workspace ID above."
        case .unauthorized: "The provider rejected access. Check the key, model and region."
        case .rateLimited: "The provider rate-limited this request. No automatic retry was made."
        case .network: "Could not reach the provider. Check your connection."
        case .expired: "The 12-second deadline elapsed. No automatic retry was made."
        case .cancelled: "Test cancelled."
        case .emptyOutput, .incompleteOutput, .outputTooLong, .invalidOutput:
            "The response was empty, incomplete or unsuitable for a short spoken summary."
        case .httpError: "The provider rejected the request. Check the text model and provider configuration."
        case .invalidResponse: "The provider returned an unsupported response."
        case .disabled: "AI completion summaries are off."
        case .invalidInput, .resultTooLong: "The sample input could not be summarized."
        case .duplicate: "This completion was already handled."
        }
    }
}
