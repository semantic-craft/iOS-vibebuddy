import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct ReadAloudPreferences: View {
    @ObservedObject var reader: ReadAloud
    @ObservedObject var voiceChat: VoiceChat
    @ObservedObject var tests: SettingsTestCoordinator
    @ObservedObject var credentials: SettingsCredentials
    @AppStorage(VoiceSettings.providerKey) private var conversationChoice = VoiceProvider.qwen.rawValue
    @AppStorage(VoiceSettings.summaryProviderKey) private var summaryChoice: String?
    @AppStorage(VoiceSettings.readAloudProviderKey) private var readAloudChoice = ""

    private var status: VoiceSettings.ReadAloudStatus {
        _ = conversationChoice
        _ = summaryChoice
        _ = readAloudChoice
        return VoiceSettings.readAloudStatus()
    }

    var body: some View {
        ReadAloudPreferenceControls(status: status, reader: reader, voiceChat: voiceChat,
                                   tests: tests, credential: credentials[status.provider ?? .qwen])
            .id(status.provider?.rawValue ?? "unconfigured")
    }
}

private struct ReadAloudPreferenceControls: View {
    let status: VoiceSettings.ReadAloudStatus
    @ObservedObject var reader: ReadAloud
    @ObservedObject var voiceChat: VoiceChat
    @ObservedObject var tests: SettingsTestCoordinator
    @ObservedObject var credential: SettingsCredential
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    @AppStorage private var modelID: String
    @AppStorage private var voiceID: String
    @AppStorage private var styleID: String

    init(status: VoiceSettings.ReadAloudStatus, reader: ReadAloud, voiceChat: VoiceChat,
         tests: SettingsTestCoordinator, credential: SettingsCredential) {
        self.status = status
        self.reader = reader
        self.voiceChat = voiceChat
        self.tests = tests
        self.credential = credential
        let provider = status.provider ?? .qwen
        _modelID = AppStorage(wrappedValue: SpeechSynthesis.support(provider)?.defaultModel ?? "",
                              VoiceSettings.readAloudModelKey(provider))
        _voiceID = AppStorage(wrappedValue: "", VoiceSettings.readAloudVoiceKey(provider))
        _styleID = AppStorage(wrappedValue: VoiceStyle.standard.rawValue, VoiceSettings.readAloudStyleKey(provider))
    }

    private var spokenLanguage: VoiceLanguage { VoiceLanguage(rawValue: language) ?? .english }
    /// What will actually be spoken. A provider picked for the first time has
    /// nothing stored yet, and the picker shows the language default without
    /// writing it — so preview and the request must resolve it the same way
    /// rather than treat "nothing stored" as "no voice".
    private var effectiveVoice: String {
        voiceID.isEmpty
            ? VoiceSettings.readAloudVoice(status.provider ?? .qwen, language: spokenLanguage)
            : voiceID
    }
    /// `.standard` for a vendor with no instruction channel, so a persona left
    /// behind by an earlier provider cannot follow the user to one that would
    /// silently drop it.
    private var effectiveStyle: VoiceStyle {
        guard let provider = status.provider, SpeechSynthesis.supportsStyle(provider) else { return .standard }
        return VoiceStyle(stored: styleID)
    }
    private var configuration: SpeechSynthesisConfiguration {
        let value = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(provider: status.provider ?? .qwen,
                     model: modelID.trimmingCharacters(in: .whitespacesAndNewlines), voice: effectiveVoice,
                     qwenWorkspaceID: value.isEmpty ? nil : value, qwenUseIntl: intl,
                     style: effectiveStyle, language: spokenLanguage)
    }
    /// Why preview cannot run — the same order the status pill reports.
    private var previewFailure: String? {
        if let unavailable = ReadAloud.unavailability(status) { return unavailable }
        guard let provider = status.provider else { return nil }
        if !credential.configured {
            return String(format: NSLocalizedString("Save your %@ API key first.", comment: "Read-aloud needs a key"), provider.display)
        }
        if configuration.model.isEmpty { return NSLocalizedString("Enter a speech synthesis model before previewing.", comment: "Read-aloud model missing") }
        if effectiveVoice.isEmpty { return NSLocalizedString("Enter a voice ID or use the language default.", comment: "Read-aloud voice missing") }
        if provider == .qwen {
            let config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: configuration.model,
                qwenUseIntl: intl, qwenWorkspaceID: workspace)
            if config.configurationFailure != nil { return NSLocalizedString("Check the Qwen workspace ID in the account below.", comment: "Qwen workspace invalid") }
        }
        if voiceChat.isActive { return NSLocalizedString("Stop the current voice conversation or reading before previewing.", comment: "Read-aloud busy") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let provider = status.provider {
                HStack(alignment: .top, spacing: 12) {
                    Text("Read-aloud voice").frame(width: 100, alignment: .leading)
                    VoicePicker(label: "Read-aloud voice", purpose: .readAloud, provider: provider,
                                language: spokenLanguage,
                                fallback: VoiceSettings.readAloudVoice(provider, language: spokenLanguage),
                                voiceID: $voiceID, trailing: { EmptyView() }, showsDetails: false)
                        .frame(maxWidth: 340, alignment: .leading)
                        .disabled(configuration.styledVoice != nil)
                }
            }
            HStack(spacing: 12) {
                Text("Announcer style").frame(width: 100, alignment: .leading)
                Picker("Announcer style", selection: styleSelection) {
                    ForEach(VoiceStyle.allCases, id: \.rawValue) { Text(verbatim: $0.display).tag($0.rawValue) }
                }
                .labelsHidden().fixedSize()
                .disabled(status.provider.map { !SpeechSynthesis.supportsStyle($0) } ?? true)
                .accessibilityLabel("Announcer style").accessibilityIdentifier("readAloudStyle")
                Button(isPreviewing ? "Stop preview" : "Preview voice", action: preview)
                    .disabled(isPreviewing ? false : previewFailure != nil || reader.busy || tests.isBusy)
                    .help(isPreviewing ? "Stop the preview." : "Play one sample line. This calls the provider and is billed.")
                    .accessibilityLabel("Preview the read-aloud voice").accessibilityIdentifier("readAloudPreview")
                Spacer(minLength: 0)
            }
            if let unavailable = ReadAloud.unavailability(status) {
                Text(unavailable).foregroundStyle(MacTheme.ink2)
            } else if let provider = status.provider, !SpeechSynthesis.supportsStyle(provider) {
                Text("This provider uses Standard delivery. Choose another read-aloud provider to change the style.")
                    .foregroundStyle(MacTheme.ink2)
            } else {
                if configuration.styledVoice != nil {
                    Text("This style reads with its own voice and model, and rewords summaries. The voice and model set here apply to Standard.")
                        .foregroundStyle(MacTheme.ink2)
                }
                Text("Voice and style changes apply to the next reading. Current playback continues.")
                    .foregroundStyle(MacTheme.ink2)
            }
            if status.provider != nil, let previewFailure {
                Text(previewFailure).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            }
            SettingsOperationAvailability(tests: tests, purpose: .readAloud, reading: reader.busy)
            SettingsTestFeedback(tests: tests, purpose: .readAloud)
        }
        .font(MacTheme.font(12)).controlSize(.small)
        .onAppear { credential.refresh() }
        .onChange(of: [modelID, voiceID, styleID, language, workspace, String(intl), String(credential.revision)]) { _, _ in
            if tests.purpose == .readAloud { tests.invalidate() }
        }
        .onChange(of: voiceChat.isActive) { _, active in
            if active, tests.purpose == .readAloud { tests.cancel() }
        }
        .onDisappear { if tests.purpose == .readAloud { tests.invalidate() } }
    }

    /// This row owns the running test, so its button reads and acts as Stop.
    private var isPreviewing: Bool { tests.purpose == .readAloud && tests.isBusy }

    /// Reads through the same normalisation the request uses, so a stored
    /// persona this build cannot parse shows as Standard instead of leaving
    /// the picker with no matching tag.
    private var styleSelection: Binding<String> {
        Binding(get: { effectiveStyle.rawValue }, set: { styleID = $0 })
    }

    private func preview() {
        if isPreviewing { tests.cancel(); return }
        guard previewFailure == nil, !tests.isBusy, !reader.busy else { return }
        credential.load()
        guard credential.configured else { return tests.reportUnreadableKey(.readAloud) }
        let config = configuration, key = credential.value, reader = reader
        let text = config.style.previewLine(config.language)
            ?? NSLocalizedString("Hello, I’m your work companion. The task is complete, and device verification is still pending.", comment: "Synthetic read-aloud preview")
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
