import SwiftUI
import VibeBuddyKit

struct SummarySpeechSettingsView: View {
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var voice: VoiceChat
    @EnvironmentObject private var announcer: PhoneAnnouncer
    @State private var draft = ContentStyleConfiguration.default
    @State private var baseline: ContentStyleState?
    @State private var hasUserEdits = false
    @AppStorage(PhoneReadAloudSelection.defaultsKey) private var selectionRaw = ""
    @AppStorage(PhoneReadAloudSelection.languageKey) private var previewLanguage = ""
    @State private var providerWithKey: VoiceProvider?

    private var selection: PhoneReadAloudSelection { PhoneReadAloudSelection(rawValue: selectionRaw) }
    private var dirty: Bool { baseline.map { $0.configuration != draft } ?? false }

    private var previewUnavailableReason: LocalizedStringKey? {
        if announcer.isPreviewing { return nil }
        if voice.phase != .idle { return "End the voice conversation before previewing." }
        if announcer.isBusy { return "Wait for the current reading to finish or stop it before previewing." }
        if case .provider(let provider) = selection, providerWithKey != provider {
            return "Configure this provider’s API key or choose System speech."
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                if let saved = dashboard.contentStyleState {
                    LabeledContent("Current content style") { Text(LocalizedStringKey(saved.configuration.style.title)) }
                    if dashboard.state != .connected {
                        Label("Offline · showing the last confirmed setting", systemImage: "wifi.slash")
                    }
                    Picker("Content style", selection: Binding(get: { draft.style }, set: { draft.style = $0; hasUserEdits = true })) {
                        ForEach(ContentStyle.allCases, id: \.self) { Text(LocalizedStringKey($0.title)).tag($0) }
                    }
                    .accessibilityIdentifier("phone-content-style")
                    if draft.style == .custom {
                        TextEditor(text: Binding(get: { draft.customPrompt }, set: { draft.customPrompt = $0; hasUserEdits = true }))
                            .frame(minHeight: 120)
                            .accessibilityLabel("Custom prompt")
                            .accessibilityIdentifier("phone-content-prompt")
                        Text("\(draft.customPrompt.count) / 2000")
                            .foregroundStyle(draft.customPrompt.count > 2000 ? .red : .secondary)
                        if draft.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Enter instructions before saving a custom style.").foregroundStyle(.secondary)
                        }
                    }
                    if let baseline, baseline.revision != saved.revision, hasUserEdits {
                        Text("Mac settings changed. Your draft is kept. Review the current setting before saving again.")
                        Button("Keep draft and use current revision") { self.baseline = saved }
                    }
                    Button(dashboard.contentStyleSaving ? "Saving…" : "Save to current Mac") {
                        guard let baseline else { return }
                        let submitted = draft
                        let sourceIdentity = dashboard.speechSourceIdentity
                        Task {
                            if await dashboard.saveContentStyle(submitted, expectedRevision: baseline.revision),
                               sourceIdentity == dashboard.speechSourceIdentity {
                                self.baseline = dashboard.contentStyleState
                                if draft == submitted { draft = dashboard.contentStyleState?.configuration ?? draft; hasUserEdits = false }
                            }
                        }
                    }
                    .disabled(!dirty || !draft.isValid || draft.customPrompt.count > 2000
                              || dashboard.state != .connected || dashboard.contentStyleSaving
                              || baseline?.revision != saved.revision)
                    .accessibilityIdentifier("phone-save-content-style")
                } else {
                    Text("Connect to your Mac to load its content style.")
                }
                if dashboard.contentStyleLoading { ProgressView() }
                if let message = dashboard.contentStyleMessage { Text(message).foregroundStyle(.secondary) }
                Button("Refresh from Mac") { Task { await dashboard.loadContentStyle() } }
                    .disabled(dashboard.state != .connected || dashboard.contentStyleSaving)
            } header: {
                Text(connection.pairing?.macName ?? String(localized: "Current Mac"))
            } footer: {
                Text("Content style is saved on the connected Mac and applies to its summaries. Unsaved edits stay on this screen.")
            }

            Section {
                Picker("Reading language", selection: $previewLanguage) {
                    Text("Follow conversation language").tag("")
                    Text("English").tag(VoiceLanguage.english.rawValue)
                    Text("简体中文").tag(VoiceLanguage.chinese.rawValue)
                }
                .accessibilityIdentifier("phone-reading-language")
                Text("Reading language controls the device voice. Summary wording and language are configured on your Mac.").foregroundStyle(.secondary)
                Picker("Speech service", selection: $selectionRaw) {
                    Text("System speech").tag("system")
                    ForEach(VoiceProvider.allCases.filter { SpeechSynthesis.support($0) != nil }, id: \.rawValue) {
                        Text($0.display).tag($0.rawValue)
                    }
                }
                .accessibilityIdentifier("phone-speech-service")
                if case .provider(let provider) = selection {
                    PhoneProviderSpeechSettings(provider: provider, language: PhoneReadAloudSelection.language(), providerWithKey: $providerWithKey).id(provider.rawValue)
                } else {
                    Text("System speech uses the device voice. Presenter style is unavailable.").foregroundStyle(.secondary)
                }
                Button(announcer.isPreviewing ? "Stop preview" : "Preview voice") {
                    if announcer.isPreviewing { announcer.cancelPreview() }
                    else { announcer.preview() }
                }
                .disabled(previewUnavailableReason != nil)
                .accessibilityIdentifier("phone-preview-voice")
                if let reason = previewUnavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                        .accessibilityIdentifier("phone-preview-unavailable")
                }
                if announcer.canUseSystemSpeech {
                    Button("Read this item with system speech") { announcer.useSystemSpeech() }
                        .disabled(voice.phase != .idle)
                }
                if let message = announcer.previewMessage { Text(message).foregroundStyle(.secondary) }
                if announcer.isPreviewing, let status = announcer.status { Text(status).foregroundStyle(.secondary) }
            } header: {
                Text("Read aloud on this iPhone")
            } footer: {
                Text("Summaries are generated on your Mac. Audio plays on this iPhone. API keys are saved separately on each device. Reading language and voice apply to the next announcement; voice conversation keeps its own settings.")
            }
        }
        .phoneList()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Summary & speech")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            selectionRaw = PhoneReadAloudSelection.load().rawValue
            adoptConfirmedValue()
            await dashboard.loadContentStyle()
            adoptConfirmedValue()
        }
        .onChange(of: dashboard.contentStyleState) { _, _ in adoptConfirmedValue() }
        .onChange(of: dashboard.speechSourceIdentity) { _, _ in
            baseline = nil
            hasUserEdits = false
            draft = .default
            adoptConfirmedValue()
        }
        .onChange(of: selectionRaw) { _, _ in announcer.cancelPreview() }
        .onChange(of: previewLanguage) { _, _ in announcer.cancelPreview() }
        .onChange(of: voice.phase) { _, phase in
            if phase != .idle { announcer.cancelPreview() }
        }
        .onDisappear { announcer.cancelPreview() }
    }

    private func adoptConfirmedValue() {
        guard let saved = dashboard.contentStyleState else { return }
        if baseline == nil || !hasUserEdits {
            baseline = saved
            draft = saved.configuration
        }
    }
}

private struct PhoneProviderSpeechSettings: View {
    let provider: VoiceProvider
    let language: VoiceLanguage
    @EnvironmentObject private var announcer: PhoneAnnouncer
    @Binding var providerWithKey: VoiceProvider?
    @State private var model = ""
    @State private var selectedVoice = ""
    @State private var style = VoiceStyle.standard
    @State private var key = ""
    @FocusState private var editingKey: Bool
    @State private var keyMessage: String?
    @State private var keySaved = false
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""

    private func saveKey(_ value: String?) {
        guard KeychainStore.set(value, for: provider.keychainAccount) == 0 else {
            keyMessage = String(localized: "Could not update the saved key. Your previous key is unchanged.")
            return
        }
        key = ""
        editingKey = false
        keySaved = value != nil
        providerWithKey = keySaved ? provider : nil
        keyMessage = value == nil ? String(localized: "API key deleted from this iPhone") : String(localized: "API key updated on this iPhone")
        announcer.cancelPreview()
    }

    var body: some View {
        let configuration = VoiceSettings.readAloudConfiguration(provider, language: language)
        let voices = VoiceCatalog.voices(.readAloud, provider)
        let styledVoice = style.voice(for: provider, language: configuration.language, qwenUseIntl: intl)
        let standardVoice = selectedVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? configuration.voice : selectedVoice
        let displayedVoice = styledVoice?.voice ?? standardVoice
        let voiceSelection = Binding(get: { styledVoice?.voice ?? standardVoice }, set: { value in
            selectedVoice = value
            UserDefaults.standard.set(value, forKey: VoiceSettings.readAloudVoiceKey(provider))
            announcer.cancelPreview()
        })
        Picker("Voice tone", selection: voiceSelection) {
            ForEach(voices, id: \.id) { Text($0.name).tag($0.id) }
            if !displayedVoice.isEmpty, !voices.contains(where: { $0.id == displayedVoice }) {
                Text(displayedVoice).tag(displayedVoice)
            }
        }
        .accessibilityIdentifier("phone-reading-voice")
        .disabled(SpeechSynthesis.supportsStyle(provider) && style.voice(for: provider, language: configuration.language, qwenUseIntl: intl) != nil)
        if SpeechSynthesis.supportsStyle(provider) {
            Picker("Presenter style", selection: $style) {
                ForEach(VoiceStyle.allCases, id: \.rawValue) { Text($0.display).tag($0) }
            }
            if style.voice(for: provider, language: configuration.language, qwenUseIntl: intl) != nil {
                Text("This style reads with its own voice and model, and rewords summaries. The voice and model set here apply to Standard.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("This speech service does not support presenter styles.").foregroundStyle(.secondary)
        }
        if !keySaved { Text("Configure this provider’s API key or choose System speech.").foregroundStyle(.secondary) }
        DisclosureGroup("Service settings") {
            Text(keySaved ? "API key saved on this iPhone" : "No API key saved on this iPhone")
            SecureField("New API key", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("phone-api-key-draft")
                .focused($editingKey)
            Button("Save API key") { saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("phone-save-api-key")
            Button("Cancel key edit") { key = ""; keyMessage = nil; editingKey = false }
                .disabled(key.isEmpty)
            if keySaved {
                Button("Delete saved API key", role: .destructive) { saveKey(nil) }
            }
            Link("Get an API key", destination: provider.apiKeyURL)
            if let keyMessage { Text(keyMessage).foregroundStyle(.secondary) }
            TextField("Speech model", text: Binding(get: { styledVoice?.model ?? model }, set: { model = $0 })).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(SpeechSynthesis.supportsStyle(provider) && style.voice(for: provider, language: configuration.language, qwenUseIntl: intl) != nil)
            if let modelURL = provider.modelDocumentationURL(for: .speechSynthesis, model: styledVoice?.model ?? model) {
                Link("Speech synthesis model help", destination: modelURL)
                    .accessibilityIdentifier("phone-speech-model-help")
            }
            TextField("Voice ID", text: voiceSelection).textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(SpeechSynthesis.supportsStyle(provider) && style.voice(for: provider, language: configuration.language, qwenUseIntl: intl) != nil)
            if provider == .qwen {
                TextField("Workspace ID", text: $workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Use Singapore (international) region", isOn: $intl)
            }
            if provider == .minimax {
                Text("Use a MiniMax China Token Plan key for speech on this iPhone. The default speech model is Speech 2.8 Turbo. Configure the summary model and its key on your Mac.").foregroundStyle(.secondary)
            } else {
                Text("Credentials and region are shared with this provider’s voice conversation on this iPhone.").foregroundStyle(.secondary)
            }
        }
        .onAppear {
            model = configuration.model
            // Keep an absent override absent so changing language recomputes its default.
            selectedVoice = UserDefaults.standard.string(forKey: VoiceSettings.readAloudVoiceKey(provider)) ?? ""
            style = configuration.style
            keySaved = provider.hasAPIKey
            providerWithKey = keySaved ? provider : nil
        }
        .onChange(of: model) { _, value in
            UserDefaults.standard.set(value, forKey: VoiceSettings.readAloudModelKey(provider))
            announcer.cancelPreview()
        }
        .onChange(of: style) { _, value in
            UserDefaults.standard.set(value.rawValue, forKey: VoiceSettings.readAloudStyleKey(provider))
            announcer.cancelPreview()
        }
        .onChange(of: intl) { _, _ in announcer.cancelPreview() }
        .onChange(of: workspace) { _, _ in announcer.cancelPreview() }
    }
}
