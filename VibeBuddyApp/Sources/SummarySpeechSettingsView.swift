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

    private var selection: PhoneReadAloudSelection { PhoneReadAloudSelection(rawValue: selectionRaw) }
    private var dirty: Bool { baseline.map { $0.configuration != draft } ?? false }

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
                Picker("Speech service", selection: $selectionRaw) {
                    Text("System speech").tag("system")
                    ForEach(VoiceProvider.allCases.filter { SpeechSynthesis.support($0) != nil }, id: \.rawValue) {
                        Text($0.display).tag($0.rawValue)
                    }
                }
                .accessibilityIdentifier("phone-speech-service")
                if case .provider(let provider) = selection {
                    PhoneProviderSpeechSettings(provider: provider).id(provider.rawValue)
                } else {
                    Text("System speech uses the device voice. Presenter style is unavailable.").foregroundStyle(.secondary)
                }
                Button(announcer.isPreviewing ? "Stop preview" : "Preview voice") {
                    if announcer.isPreviewing { announcer.cancelPreview() }
                    else { announcer.preview() }
                }
                .disabled(voice.phase != .idle || (announcer.isBusy && !announcer.isPreviewing))
                .accessibilityIdentifier("phone-preview-voice")
                if let message = announcer.previewMessage { Text(message).foregroundStyle(.secondary) }
                if announcer.isPreviewing, let status = announcer.status { Text(status).foregroundStyle(.secondary) }
            } header: {
                Text("Read aloud on this iPhone")
            } footer: {
                Text("Voice and presenter style apply to the next announcement on this iPhone. Voice conversation has its own service selection. Preview is available when reading and voice calls are idle.")
            }
        }
        .phoneList()
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
    @State private var model = ""
    @State private var selectedVoice = ""
    @State private var style = VoiceStyle.standard
    @State private var key = ""
    @State private var keySaveFailed = false
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""

    var body: some View {
        let configuration = VoiceSettings.readAloudConfiguration(provider)
        let voices = VoiceCatalog.voices(.readAloud, provider)
        Picker("Voice tone", selection: $selectedVoice) {
            ForEach(voices, id: \.id) { Text($0.name).tag($0.id) }
            if !selectedVoice.isEmpty, !voices.contains(where: { $0.id == selectedVoice }) {
                Text(selectedVoice).tag(selectedVoice)
            }
        }
        if SpeechSynthesis.supportsStyle(provider) {
            Picker("Presenter style", selection: $style) {
                ForEach(VoiceStyle.allCases, id: \.rawValue) { Text($0.display).tag($0) }
            }
        } else {
            Text("This speech service does not support presenter styles.").foregroundStyle(.secondary)
        }
        if !provider.hasAPIKey { Text("Configure this provider’s API key or choose System speech.").foregroundStyle(.secondary) }
        DisclosureGroup("Service settings") {
            SecureField("API key", text: Binding(get: { key }, set: { value in
                key = value
                keySaveFailed = KeychainStore.set(value, for: provider.keychainAccount) != 0
            }))
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            Link("Get an API key", destination: provider.apiKeyURL)
            if keySaveFailed { Text("API key could not be saved. Your edit is not stored; edit or paste it again to retry.").foregroundStyle(.orange) }
            TextField("Speech model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Voice ID", text: $selectedVoice).textInputAutocapitalization(.never).autocorrectionDisabled()
            if provider == .qwen {
                TextField("Workspace ID", text: $workspace).textInputAutocapitalization(.never).autocorrectionDisabled()
                Toggle("Use Singapore (international) region", isOn: $intl)
            }
            Text("Credentials and region are shared with this provider’s voice conversation on this iPhone.").foregroundStyle(.secondary)
        }
        .onAppear {
            model = configuration.model
            selectedVoice = configuration.voice
            style = configuration.style
            key = provider.apiKey ?? ""
        }
        .onChange(of: model) { _, value in UserDefaults.standard.set(value, forKey: VoiceSettings.readAloudModelKey(provider)) }
        .onChange(of: selectedVoice) { _, value in UserDefaults.standard.set(value, forKey: VoiceSettings.readAloudVoiceKey(provider)) }
        .onChange(of: style) { _, value in UserDefaults.standard.set(value.rawValue, forKey: VoiceSettings.readAloudStyleKey(provider)) }
    }
}
