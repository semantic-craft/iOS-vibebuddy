import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct ReadAloudSettings: View {
    @ObservedObject var reader: ReadAloud
    @ObservedObject var voiceChat: VoiceChat
    @ObservedObject var tests: SettingsTestCoordinator
    /// The resolved provider's saved key. Read-aloud has no credential of its
    /// own: it edits the same account the rest of Settings edits.
    @ObservedObject var credential: SettingsCredential
    @Binding var providerSelection: String
    /// Resolved once by the caller so the picker, the fields and the preview all
    /// speak about the same provider.
    let status: VoiceSettings.ReadAloudStatus
    let credentialsEditedElsewhere: Bool
    @AppStorage(ReadAloud.enabledKey) private var enabled = false
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var summariesEnabled = false
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    @AppStorage private var model: String
    @AppStorage private var voice: String

    init(reader: ReadAloud, voiceChat: VoiceChat, tests: SettingsTestCoordinator,
         credential: SettingsCredential, providerSelection: Binding<String>,
         status: VoiceSettings.ReadAloudStatus, credentialsEditedElsewhere: Bool) {
        self.reader = reader
        self.voiceChat = voiceChat
        self.tests = tests
        self.credential = credential
        _providerSelection = providerSelection
        self.status = status
        self.credentialsEditedElsewhere = credentialsEditedElsewhere
        // Fields follow the resolved provider; the caller re-creates this view when it changes.
        let provider = status.provider ?? .qwen
        _model = AppStorage(wrappedValue: SpeechSynthesis.support(provider)?.defaultModel ?? "",
                            VoiceSettings.readAloudModelKey(provider))
        _voice = AppStorage(wrappedValue: SpeechSynthesis.support(provider)?.defaultVoice ?? "",
                            VoiceSettings.readAloudVoiceKey(provider))
    }

    private var configuration: SpeechSynthesisConfiguration {
        let value = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(provider: status.provider ?? .qwen,
                     model: model.trimmingCharacters(in: .whitespacesAndNewlines), voice: voice,
                     qwenWorkspaceID: value.isEmpty ? nil : value, qwenUseIntl: intl)
    }
    private var configurationFailure: String? {
        if let unavailable = ReadAloud.unavailability(status) { return unavailable }
        let provider = configuration.provider
        if !credential.configured { return String(format: NSLocalizedString("Save your %@ API key first.", comment: "Read-aloud needs a key"), provider.display) }
        if configuration.model.isEmpty { return NSLocalizedString("Enter a speech synthesis model before previewing.", comment: "Read-aloud model missing") }
        if voice.isEmpty { return NSLocalizedString("Enter a voice ID or use the language default.", comment: "Read-aloud voice missing") }
        if provider == .qwen {
            let config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: configuration.model,
                qwenUseIntl: intl, qwenWorkspaceID: workspace)
            if config.configurationFailure != nil { return NSLocalizedString("Check the Qwen workspace ID in Provider connection.", comment: "Qwen workspace invalid") }
        }
        return nil
    }
    /// What the picker's current setting means, so "Same as summaries" is legible
    /// without opening the summaries row.
    private var providerNote: String {
        if let unavailable = ReadAloud.unavailability(status) { return unavailable }
        guard let provider = status.provider else { return "" }
        return providerSelection == provider.rawValue
            ? String(format: NSLocalizedString("Read-aloud uses %@, whatever the summary provider is.", comment: "Read-aloud pinned"), provider.display)
            : String(format: NSLocalizedString("Read-aloud follows the completion summary provider, currently %@.", comment: "Read-aloud follows summaries"), provider.display)
    }

    var body: some View {
        Section("Read summaries on this Mac") {
            Picker("Read-aloud provider", selection: $providerSelection) {
                Text("Same as summaries").tag("")
                ForEach(VoiceProvider.readAloudProviders, id: \.rawValue) { Text($0.display).tag($0.rawValue) }
                // A pin this build cannot offer — a provider that has since lost its
                // synthesizer, or one another build wrote — still needs a row: a picker
                // with no tag for its own selection renders undefined.
                if !providerSelection.isEmpty,
                   !VoiceProvider.readAloudProviders.contains(where: { $0.rawValue == providerSelection }) {
                    Text(VoiceProvider(rawValue: providerSelection)?.display ?? providerSelection)
                        .tag(providerSelection)
                }
            }
            Text(verbatim: providerNote).font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically read AI completion summaries for followed tasks", isOn: $enabled)
            if !summariesEnabled {
                Text("Automatic reading needs AI completion summaries to be enabled and successfully generated. Previewing does not enable either feature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if case .ready(let provider) = status {
                Text("Generate speech with your read-aloud provider and play it through your Mac’s current audio output. No microphone is needed. Each reading incurs speech-generation charges.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Speech synthesis model", text: $model)
                    .font(.body.monospaced()).autocorrectionDisabled()
                // Qwen's own TTS voices. The built-in per-provider voice catalogue replaces this picker.
                Picker("Read-aloud voice", selection: $voice) {
                    Text("Longan Fengyue · Warm and natural").tag("longanfengyue")
                    Text("Longan Lingxi · Sweet and cheerful").tag("longanlingxi")
                    Text("Longan Yuanfei · Female character voice").tag("longanyuanfei")
                    if !["longanfengyue", "longanlingxi", "longanyuanfei"].contains(voice) {
                        Text(verbatim: voice).tag(voice)
                    }
                }
                if credentialsEditedElsewhere {
                    Text("Credentials, region and workspace are shared with the selected provider. Edit them in Provider connection below.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Read-aloud provider connection") {
                        Text("These credentials are also used when this provider is selected for conversation or summaries.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            SecureField("API key", text: keyInput)
                                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                            Button("Paste") {
                                guard let value = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
                                keyInput.wrappedValue = value
                            }
                        }
                        Link("Get an API key", destination: provider.apiKeyURL)
                        if provider == .qwen {
                            Toggle("Use Singapore (international) region", isOn: $intl)
                            TextField("Workspace ID — optional; uses the workspace endpoint when set", text: $workspace)
                                .font(.body.monospaced()).autocorrectionDisabled()
                            Link("Find your workspace ID", destination: VoiceProvider.qwenWorkspaceIDURL)
                        }
                    }
                }
                if credential.saveFailed {
                    Text("API key could not be saved. Your edit is not stored; edit or paste it again to retry.")
                        .foregroundStyle(.orange)
                }
                if let failure = configurationFailure {
                    Text(verbatim: failure).foregroundStyle(.secondary)
                }
                if voiceChat.isActive {
                    Text("Stop the current voice conversation or reading before previewing.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Preview read-aloud voice", action: preview)
                        .disabled(tests.isBusy || reader.busy || voiceChat.isActive || configurationFailure != nil)
                    Button("Stop") { tests.cancel() }
                        .disabled(tests.purpose != .readAloud || !tests.isBusy)
                }
                Text("Preview sends only the sample text to your read-aloud provider and may incur a speech-generation charge. It does not enable automatic reading or use the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
                if tests.purpose == .readAloud, tests.phase == .running {
                    Text("Read-aloud preview").font(.headline)
                    if !reader.previewStatus.isEmpty { Text(LocalizedStringKey(reader.previewStatus)).font(.caption) }
                }
                if tests.purpose != .readAloud { Text("Not verified").foregroundStyle(.secondary) }
                SettingsTestFeedback(tests: tests, purpose: .readAloud)
            }
            if reader.automaticBusy || !reader.status.isEmpty {
                Text("Automatic reading").font(.headline)
                if reader.automaticBusy && tests.purpose == .readAloud && tests.isBusy {
                    Text("Automatic reading is queued until the preview finishes.").font(.caption)
                } else if !reader.status.isEmpty {
                    Text(LocalizedStringKey(reader.status)).font(.caption)
                }
                Button("Stop automatic reading") { reader.stopAutomaticReading() }
                    .disabled(!reader.automaticBusy)
            }
        }
        .onChange(of: enabled) { _, on in
            tests.invalidate()
            if !on { reader.stop() } // Preserve the existing explicit opt-out behavior.
        }
        .onChange(of: model) { _, _ in tests.invalidate(); reader.stop() }
        .onChange(of: voice) { _, _ in tests.invalidate(); reader.stop() }
        .onChange(of: [String(credential.revision), workspace, String(intl)]) { _, _ in tests.invalidate() }
        .onChange(of: voiceChat.isActive) { _, active in
            if active, tests.purpose == .readAloud { tests.cancel() }
        }
        .onAppear { credential.load() }
        .onDisappear { tests.invalidate() }
    }

    private var keyInput: Binding<String> {
        Binding(get: { credential.value }, set: { credential.edit($0); tests.invalidate() })
    }

    private func preview() {
        guard !tests.isBusy, !reader.busy, !voiceChat.isActive, configurationFailure == nil else { return }
        let config = configuration, key = credential.value, reader = reader
        let text = NSLocalizedString("Hello, I’m your work companion. The task is complete, and device verification is still pending.", comment: "Synthetic read-aloud preview")
        tests.start(.readAloud, timeout: .seconds(35), operation: {
            switch await reader.preview(text, apiKey: key, configuration: config) {
            case .completed:
                return .success(.init(message: "Read-aloud preview playback completed on this Mac. Confirm that you heard it through the intended output."))
            case .cancelled: return .cancelled
            case .failed(let message): return .failure(message)
            }
        }, cleanup: { await reader.cancelPreview() })
    }
}
