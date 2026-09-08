import SwiftUI
import VibeBuddyKit

/// Native directory separating phone preferences, Mac information, and help.
/// Preference state remains owned by the sheet across navigation destinations.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var voice: VoiceChat
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connection: ConnectionStore
    @AppStorage(SoundPrefs.playSoundKey) private var playSound = true
    @AppStorage(SoundPrefs.quietModeKey) private var quiet = false
    @ObservedObject var connectionTest: VoiceConnectionTest
    @State private var quietHours = SoundPrefs.quietHours
    @State private var categories = SoundPrefs.categories
    @AppStorage(VoiceSettings.conversationLanguageKey) private var voiceLanguage = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.providerKey) private var provider = VoiceProvider.qwen.rawValue
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    var body: some View {
        NavigationStack {
            Form {
                Section("This iPhone") {
                    NavigationLink { notificationSettings } label: {
                        Label("Notifications & sounds", systemImage: "bell.badge")
                    }
                    NavigationLink { voiceSettings } label: {
                        Label("Voice conversation", systemImage: "waveform")
                    }
                }
                Section("Connected Mac") {
                    NavigationLink { connectionDetails } label: {
                        Label("Connection information", systemImage: "desktopcomputer")
                    }
                    NavigationLink { completionSummaryInfo } label: {
                        Label("Completion summaries", systemImage: "text.alignleft")
                    }
                }
                Section("Help") {
                    NavigationLink { observationDiagnostics } label: {
                        Label("Observation health", systemImage: "waveform.path.ecg")
                    }
                    NavigationLink { MacCompanionSetupView() } label: {
                        Label("Download or update the Mac app", systemImage: "arrow.down.circle")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onDisappear { connectionTest.invalidate() }
    }

    private var notificationSettings: some View {
        Form {
            Section {
                ForEach(NotificationCategoryPrefs.displayOrder, id: \.rawValue) { category in
                    Toggle(category.categoryTitle, isOn: Binding(
                        get: { categories.isEnabled(category) },
                        set: { categories.set(category, enabled: $0) }))
                }
            } header: {
                Text("Notify me about")
            } footer: {
                Text("Disabled categories never notify your iPhone or Apple Watch. Quiet mode and quiet hours silence session alerts except silent approvals and questions. Enabled quota alerts are unaffected.")
            }

            Section {
                Toggle("Sound", isOn: $playSound)
                Toggle("Quiet mode (quota unaffected)", isOn: $quiet).disabled(!playSound)
            } header: {
                Text("Sound")
            } footer: {
                Text("Status changes can play a short cue. Quiet mode keeps approvals and questions silent and suppresses other session alerts. Enabled quota alerts still follow the Sound setting.")
            }

            Section {
                Toggle("Auto-mute at night", isOn: $quietHours.enabled).disabled(!playSound)
                if quietHours.enabled {
                    Picker("Start", selection: $quietHours.startHour) { hourTags }
                    Picker("End", selection: $quietHours.endHour) { hourTags }
                }
            } header: {
                Text("Night")
            } footer: {
                Text("During this window Quiet mode applies to session alerts. Enabled quota alerts are unaffected.")
            }
        }
        .navigationTitle("Notifications & sounds")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: playSound) { _, _ in reportPrefs() }
        .onChange(of: quiet) { _, _ in reportPrefs() }
        .onChange(of: quietHours) { _, q in SoundPrefs.setQuietHours(q); reportPrefs() }
        .onChange(of: categories) { _, c in SoundPrefs.categories = c; reportPrefs() }
    }

    private var voiceSettings: some View {
        Form {
            Section {
                Toggle("Voice companion", isOn: $companionEnabled)
                    .onChange(of: companionEnabled) { _, on in if !on { voice.companionDisabled() } }
                Picker("Voice provider", selection: Binding(get: { provider }, set: { raw in
                    guard let selected = VoiceProvider(rawValue: raw) else { return }
                    VoiceSettings.selectVoiceProvider(selected)
                    provider = raw
                })) {
                    ForEach(VoiceProvider.allCases, id: \.rawValue) { p in
                        Text(p.display).tag(p.rawValue)
                    }
                }
                .onChange(of: provider) { _, _ in connectionTest.invalidate(); voice.reloadProviderIfActive() }
                Picker("Conversation language", selection: $voiceLanguage) {
                    Text("English").tag(VoiceLanguage.english.rawValue)
                    Text("中文").tag(VoiceLanguage.chinese.rawValue)
                }
                .onChange(of: voiceLanguage) { _, _ in connectionTest.invalidate(); voice.reloadProviderIfActive() }
            } header: {
                Text("Voice companion")
            } footer: {
                Text("Optional and off by default. When you start a voice conversation, your microphone audio and selected session context (project names, agent type, status, and summaries) are sent directly to your selected provider — Qwen (DashScope), OpenAI, Gemini (Google), or Doubao (Volcengine) — using your own API key. The key stays in Keychain and nothing passes through a vibebuddy server.")
            }

            // Only the selected provider's credentials show — key + editable
            // Model ID + Voice ID — and they swap as the picker changes. `.id`
            // recreates the section so its fields reload for the new provider.
            if let p = VoiceProvider(rawValue: provider) {
                ProviderSection(provider: p, connectionTest: connectionTest).id(p.rawValue)
            }
        }
        .navigationTitle("Voice conversation")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: provider)
    }

    private var observationDiagnostics: some View {
        Form {
            if dashboard.state != .connected && !dashboard.observationDiagnostics.isEmpty {
                Section {
                    Label("Showing last diagnostics. Reconnect to update.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                if dashboard.observationDiagnostics.isEmpty {
                    Text("No observation diagnostics received from the Mac yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(dashboard.observationDiagnostics) { agent in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(agent.agent.displayName).font(.headline)
                        ForEach(agent.sources) { source in
                            ObservationDiagnosticRow(source: source)
                        }
                    }
                }
            } header: {
                Text("Observation health")
            } footer: {
                Text("Each row describes one source. Configuration changes are made on the Mac; a healthy source does not verify every session or its approvals.")
            }
        }
        .navigationTitle("Observation health")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionDetails: some View {
        Form {
            Section("Connection information") {
                LabeledContent("Status") { Text(connectionStatus) }
                if let pairing = connection.pairing {
                    if let name = pairing.macName, !name.isEmpty {
                        LabeledContent("Mac") { Text(name).textSelection(.enabled) }
                    }
                    LabeledContent("Address") {
                        Text("\(pairing.host):\(pairing.port)")
                            .textSelection(.enabled)
                    }
                }
                if connection.pairing != nil, case .failed(let message) = dashboard.state {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                NavigationLink { MacCompanionSetupView() } label: {
                    Label("Pairing and Mac setup", systemImage: "qrcode")
                }
            } footer: {
                Text("Pair by scanning the code from your Mac. Use the Mac menu at the top of the dashboard to reconnect or forget the current pairing.")
            }
        }
        .navigationTitle("Connection information")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var connectionStatus: String {
        if connection.demo { return String(localized: "Demo — no Mac connected") }
        guard connection.pairing != nil else { return String(localized: "Not paired") }
        switch dashboard.state {
        case .connecting: return String(localized: "Connecting")
        case .connected: return String(localized: "Online")
        case .failed: return String(localized: "Offline")
        }
    }

    private var completionSummaryInfo: some View {
        Form {
            Section {
                Text("Completion summaries are configured and generated on your Mac. Choose the summary provider, model and credentials in the Mac app's Settings.")
                Text("Your iPhone receives the Mac's completion notice. There is no separate summary model or remote configuration control on this iPhone.")
            } header: {
                Text("Managed on your Mac")
            }
            Section {
                Text("Voice conversation on this iPhone has its own provider and credentials. Changing voice settings does not configure Mac completion summaries or Mac read aloud.")
            } header: {
                Text("Separate from iPhone voice")
            }
        }
        .navigationTitle("Completion summaries")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hourTags: some View {
        ForEach(0..<24, id: \.self) { h in
            Text(String(format: "%02d:00", h)).tag(h)
        }
    }

    /// Tell the Mac so its background push respects the new prefs.
    private func reportPrefs() {
        if ProcessInfo.processInfo.environment["VIBEBUDDY_SKIP_NOTIFICATIONS"] != "1" {
            PushRegistration.shared.reportPrefs()
        }
    }
}

/// Credentials + editable Model ID and Voice ID for one voice provider. The key
/// lives in the Keychain (per-provider account); model/voice are UserDefaults.
/// blank = the provider's sensible default. Ported from the Mac Settings.
private struct ProviderSection: View {
    let provider: VoiceProvider
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspaceID = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var voice = ""
    @State private var advanced = false
    @ObservedObject var connectionTest: VoiceConnectionTest
    @State private var keyLoaded = false
    @State private var keySaveFailed = false
    private var hasKey: Bool { keyLoaded && !keySaveFailed && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var keyInput: Binding<String> {
        Binding(get: { apiKey }, set: { value in
            apiKey = value
            connectionTest.invalidate()
            keySaveFailed = KeychainStore.set(value, for: provider.keychainAccount) != 0
        })
    }
    private var effectiveModel: String {
        let value = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultModel : value
    }
    private var effectiveVoice: String {
        let value = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? provider.defaultVoice(VoiceSettings.conversationLanguage) : value
    }
    private var configurationValid: Bool {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        guard !effectiveModel.isEmpty, effectiveModel.utf8.allSatisfy(allowed.contains), !effectiveVoice.isEmpty else { return false }
        if provider == .qwen {
            let workspace = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
            return workspace.isEmpty || (workspace.count <= 63 && workspace.first != "-" && workspace.last != "-"
                && workspace.utf8.allSatisfy(host.contains))
        }
        return true
    }

    private let models = ["qwen-audio-3.0-realtime-plus", "qwen-audio-3.0-realtime-flash"]
    private let voices = ["longanqian", "longanlingxin", "longanlingxi", "longanxiaoxin", "longanlufeng"]

    var body: some View {
        Section {
            field(caption: "API Key — paste your own (kept in the Keychain)",
                  link: "Get an API key", icon: "key", url: provider.apiKeyURL, pasteInto: keyInput, id: "voiceAPIKey") {
                SecureField("Paste your \(provider.display) key", text: keyInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if provider == .qwen {
                Picker("Realtime voice model", selection: Binding(get: { model.isEmpty ? provider.defaultModel : model }, set: { model = $0 })) {
                    ForEach(models, id: \.self) { id in
                        Text(id.hasSuffix("plus") ? "Qwen Audio 3.0 Plus — recommended" : "Qwen Audio 3.0 Flash").tag(id)
                    }
                    if !model.isEmpty && !models.contains(model) {
                        Text("Custom: \(model)").tag(model)
                    }
                }
                .accessibilityIdentifier("qwenModelPicker")
                Text("Both models support live speech-to-speech. Actual response time depends on your network and region.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Voice", selection: Binding(get: { voice.isEmpty ? "longanqian" : voice }, set: { voice = $0 })) {
                    ForEach(voices, id: \.self) { id in
                        Text(id == "longanqian" ? "Recommended — longanqian" : id).tag(id)
                    }
                    if !voice.isEmpty && !voices.contains(voice) {
                        Text("Custom: \(voice)").tag(voice)
                    }
                }
                .accessibilityIdentifier("qwenVoicePicker")
                DisclosureGroup("Advanced settings", isExpanded: $advanced) {
                    customFields
                field(caption: "Workspace ID — optional; uses the workspace endpoint when set",
                      link: "Find your workspace ID", icon: "arrow.up.right.square", url: VoiceProvider.qwenWorkspaceIDURL, pasteInto: $workspaceID, id: "qwenWorkspaceID") {
                    TextField("e.g. llm-xxxxxxxx", text: $workspaceID)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("Use Singapore (international) region", isOn: $intl)
                }
                Button("Restore recommended model and voice") {
                    model = ""
                    voice = ""
                    connectionTest.invalidate()
                }
            } else if provider == .doubao {
                Text(effectiveModel == provider.defaultModel ? "Doubao realtime voice 3.0 · Recommended" : "Custom realtime model").font(.headline)
                Text(effectiveModel == provider.defaultModel && effectiveVoice == provider.defaultVoice(.english) ? "The recommended model and Vivi voice are ready. Only your realtime API key is required." : "Your custom model or voice is retained. Review Advanced settings before testing.")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced settings") {
                    customFields
                    Button("Restore recommended model and voice") { model = ""; voice = "" }
                }
            } else {
                customFields
            }
            if keySaveFailed {
                Text("API key could not be saved. Your edit is not stored; edit or paste it again to retry.").foregroundStyle(.orange)
            }
            if !configurationValid { Text("Review the realtime model, voice and connection before testing.").foregroundStyle(.secondary) }
            HStack {
                Button("Test connection", action: testConnection).disabled(!hasKey || !configurationValid || connectionTest.busy)
                if connectionTest.busy { Button("Cancel") { connectionTest.cancel() } }
            }
            Text("This test may incur provider charges. It checks configuration only, without microphone input, task history, tools or audio playback.")
                .font(.caption).foregroundStyle(.secondary)
            if let result = connectionTest.message { Text(LocalizedStringKey(result)).font(.caption) }
        } header: {
            Text(provider.display)
        }
        .onDisappear { connectionTest.invalidate() }
        .onAppear {
            guard !keyLoaded else { return }
            apiKey = provider.apiKey ?? ""
            keyLoaded = true
            model = UserDefaults.standard.string(forKey: VoiceSettings.modelKey(provider)) ?? ""
            voice = UserDefaults.standard.string(forKey: VoiceSettings.voiceKey(provider)) ?? ""
        }

        .onChange(of: model) { _, v in connectionTest.invalidate(); UserDefaults.standard.set(v, forKey: VoiceSettings.modelKey(provider)) }
        .onChange(of: intl) { _, _ in connectionTest.invalidate() }
        .onChange(of: workspaceID) { _, _ in connectionTest.invalidate() }
        .onChange(of: voice) { _, v in connectionTest.invalidate(); UserDefaults.standard.set(v, forKey: VoiceSettings.voiceKey(provider)) }
    }

    @ViewBuilder private var customFields: some View {
            field(caption: "Model ID — editable, type any model",
                  link: "Browse available models", icon: "arrow.up.right.square", url: provider.modelsURL, pasteInto: $model, id: "voiceModelID") {
                TextField(provider.defaultModel, text: $model)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field(caption: "Voice ID — editable (blank = auto by language)",
                  link: "Browse available voices", icon: "arrow.up.right.square", url: provider.voicesURL, pasteInto: $voice, id: "voiceID") {
                TextField(exampleVoice, text: $voice)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
    }

    private func testConnection() {
        guard hasKey, configurationValid, !connectionTest.busy else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let session: any RealtimeVoiceProvider
        switch provider {
        case .qwen: session = QwenRealtimeSession(apiKey: key, model: effectiveModel, workspaceID: workspace.isEmpty ? nil : workspace, useIntl: intl)
        case .openai: session = OpenAIRealtimeSession(apiKey: key, model: effectiveModel)
        case .gemini: session = GeminiRealtimeSession(apiKey: key, model: effectiveModel)
        case .doubao: session = DoubaoRealtimeSession(apiKey: key, model: effectiveModel)
        }
        connectionTest.start(session, voice: effectiveVoice)
    }

    /// One labelled, clearly-editable field with a click-through link to the
    /// provider's list of valid values.
    @ViewBuilder
    private func field<F: View>(caption: LocalizedStringKey, link: LocalizedStringKey, icon: String, url: URL,
                                pasteInto value: Binding<String>, id: String,
                                @ViewBuilder _ input: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(caption).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                input()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(id)
                PasteButton(payloadType: String.self) { values in
                    guard let pasted = values.first else { return }
                    let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    value.wrappedValue = trimmed
                }
                .labelStyle(.iconOnly)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .fixedSize()
                .accessibilityIdentifier("paste-\(id)")
            }
            Link(destination: url) {
                Label(link, systemImage: icon).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private var exampleVoice: String {
        switch provider {
        case .qwen:   return "e.g. longanqian / longanlufeng"
        case .openai: return "e.g. marin / cedar"
        case .gemini: return "e.g. Puck / Kore"
        case .doubao: return "zh_female_vv_jupiter_bigtts"
        }
    }
}
