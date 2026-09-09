import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// The three things a provider can be chosen for. Each is one row of the
/// features table — not a mode the page switches into.
enum VoiceFeature: String, CaseIterable {
    case conversation = "Voice conversation"
    case summaries = "AI completion summaries"
    case readAloud = "Read summaries aloud"

    var symbol: String {
        switch self {
        case .conversation: "waveform"
        case .summaries: "text.bubble"
        case .readAloud: "speaker.wave.2"
        }
    }
    var hint: LocalizedStringKey {
        switch self {
        case .conversation:
            "Tap the buddy to talk about your sessions. The switch does not open the microphone."
        case .summaries:
            "Sends followed tasks’ final results to this provider. Summaries may appear in notification previews."
        case .readAloud:
            "Speaks that summary through this Mac’s current audio output. No microphone; each reading is billed by the provider."
        }
    }
    var testPurpose: SettingsTestCoordinator.Purpose {
        switch self {
        case .conversation: .voice
        case .summaries: .summary
        case .readAloud: .readAloud
        }
    }
}

/// What a row says about itself, in a few words. Anything longer than a pill —
/// a configuration failure, a provider that cannot speak yet — is a `detail`
/// line under the controls instead, so the pill never grows into the row.
enum VoiceFeatureStatus: Equatable {
    case unconfigured
    /// Read-aloud following a summary provider that is not set.
    case waitingForSummaries
    /// A provider is chosen but its account has no key. Clickable.
    case needsKey(VoiceProvider)
    /// Configured, but something in it does not add up; `detail` says what.
    case needsAttention
    /// Read-aloud only: configured, but summaries are off so there is nothing to speak.
    case nothingToRead
    case verified(String)
    case unverified
}

// MARK: - The page

struct VoiceSettingsTab: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var tests: SettingsTestCoordinator
    /// Lets a feature row's "no API key" status reveal the account it needs.
    let scroll: ScrollViewProxy?
    @StateObject private var credentials = SettingsCredentials()
    @AppStorage(VoiceSettings.providerKey) private var conversationChoice = VoiceProvider.qwen.rawValue
    @AppStorage(VoiceSettings.summaryProviderKey) private var summaryChoice: String?
    @AppStorage(VoiceSettings.readAloudProviderKey) private var readAloudChoice = ""
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @State private var expandedAccount: VoiceProvider?

    private var conversationProvider: VoiceProvider? { VoiceProvider(rawValue: conversationChoice) }
    private var summaryProvider: VoiceProvider? {
        _ = summaryChoice // Re-resolve when the independent choice changes.
        return VoiceSettings.summaryProvider()
    }
    private var readAloud: VoiceSettings.ReadAloudStatus {
        _ = readAloudChoice
        _ = summaryChoice
        return VoiceSettings.readAloudStatus()
    }
    /// Which features currently point at a provider, for the account rows.
    private func features(using provider: VoiceProvider) -> [VoiceFeature] {
        var used: [VoiceFeature] = []
        if conversationProvider == provider { used.append(.conversation) }
        if summaryProvider == provider { used.append(.summaries) }
        if readAloud.provider == provider { used.append(.readAloud) }
        return used
    }
    private func reveal(_ provider: VoiceProvider) {
        expandedAccount = provider
        credentials[provider].load() // The user is about to edit it.
        withAnimation { scroll?.scrollTo(provider, anchor: .center) }
    }

    var body: some View {
        Group {
            Section("Features") {
                ConversationFeatureRow(provider: conversationProvider, menuModel: model, tests: tests,
                    credentials: credentials, selection: conversationSelection, reveal: reveal)
                    // Identity per row, not per provider: three siblings sharing an
                    // id collapse into one repeated row.
                    .id("conversation-\(conversationChoice)")
                SummaryFeatureRow(provider: summaryProvider, tests: tests, credentials: credentials,
                    reader: model.readAloud, language: language,
                    selection: summarySelection, reveal: reveal)
                    .id("summaries-\(summaryProvider?.rawValue ?? "")")
                ReadAloudFeatureRow(status: readAloud, summaryProvider: summaryProvider,
                    reader: model.readAloud, voiceChat: model.voiceChat,
                    tests: tests, credentials: credentials, selection: readAloudSelection, reveal: reveal)
                    .id("readAloud-\(readAloud.provider?.rawValue ?? "")")
            }
            Section("Provider accounts") {
                ForEach(VoiceProvider.allCases, id: \.rawValue) { provider in
                    AccountRow(provider: provider, credential: credentials[provider], tests: tests,
                        usedBy: features(using: provider),
                        expanded: Binding(get: { expandedAccount == provider },
                                          set: { expandedAccount = $0 ? provider : nil }))
                        .id(provider)
                }
                Text("A key belongs to the provider, not to a feature: every feature that selects a provider uses the same key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shared") {
                Picker("Conversation language", selection: $language) {
                    Text("English").tag(VoiceLanguage.english.rawValue)
                    Text("中文").tag(VoiceLanguage.chinese.rawValue)
                }
                .onChange(of: language) { _, _ in
                    tests.invalidate()
                    model.voiceChat.reloadProviderIfActive()
                }
                Text("Shared by all three features, and it decides which voice each provider defaults to.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: conversationChoice) { _, _ in tests.invalidate(); model.voiceChat.reloadProviderIfActive() }
        .onChange(of: summaryChoice) { _, _ in
            tests.invalidate()
            // Unpinned read-aloud follows this choice, so it just changed vendor.
            // Whatever is generating or playing came from the provider being left;
            // a pinned read-aloud is unaffected and keeps playing.
            if VoiceSettings.pinnedReadAloudProvider() == nil { model.readAloud.stop() }
        }
        .onChange(of: readAloudChoice) { _, _ in tests.invalidate(); model.readAloud.stop() }
        .onDisappear { tests.invalidate() }
    }

    private var conversationSelection: Binding<String> {
        Binding(get: { conversationChoice }, set: { raw in
            guard let value = VoiceProvider(rawValue: raw) else { return }
            VoiceSettings.selectVoiceProvider(value)
            conversationChoice = raw
        })
    }
    private var summarySelection: Binding<String> {
        Binding(get: { summaryProvider?.rawValue ?? "" }, set: { raw in
            guard raw.isEmpty || VoiceProvider(rawValue: raw)?.supportsCompletionSummaries == true else { return }
            summaryChoice = raw
        })
    }
    private var readAloudSelection: Binding<String> {
        Binding(get: { readAloudChoice }, set: { readAloudChoice = $0 })
    }
}

private extension SettingsTestCoordinator {
    /// The account holds an item but it could not be decrypted — a failed or
    /// cancelled Keychain authorization. Say so where this row's other results
    /// appear, rather than calling the provider with an empty key.
    func reportUnreadableKey(_ purpose: Purpose) {
        start(purpose, timeout: .seconds(5), operation: {
            .failure("Could not read the saved API key. Open this provider’s account below and paste the key again.")
        })
    }
}

// MARK: - Row chrome

/// One feature row: switch, name with status, the controls that provider governs,
/// one line of explanation, and this feature's own test feedback.
private struct FeatureRow<Controls: View>: View {
    let feature: VoiceFeature
    /// Read-aloud depends on the row above it; the rule says so without words.
    var dependsOnPrevious = false
    @Binding var enabled: Bool
    let status: VoiceFeatureStatus
    /// The sentence a pill cannot hold. Shown between the controls and the hint.
    var detail: String?
    var hint: LocalizedStringKey?
    @ObservedObject var tests: SettingsTestCoordinator
    let reveal: (VoiceProvider) -> Void
    @ViewBuilder let controls: Controls

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if dependsOnPrevious {
                Rectangle().fill(Color(nsColor: .separatorColor))
                    .frame(width: 2).accessibilityHidden(true)
            }
            Toggle(LocalizedStringKey(feature.rawValue), isOn: $enabled)
                .labelsHidden().toggleStyle(.switch)
                .accessibilityIdentifier("enable-\(feature.rawValue)")
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(LocalizedStringKey(feature.rawValue), systemImage: feature.symbol)
                        .font(.headline).labelStyle(.titleAndIcon)
                    Spacer(minLength: 0)
                    StatusPill(status: status, reveal: reveal)
                }
                controls
                if let detail {
                    Label(LocalizedStringKey(detail), systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(hint ?? feature.hint).font(.caption).foregroundStyle(.secondary)
                SettingsTestFeedback(tests: tests, purpose: feature.testPurpose)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusPill: View {
    let status: VoiceFeatureStatus
    let reveal: (VoiceProvider) -> Void

    var body: some View {
        switch status {
        case .unconfigured:
            pill("Not configured", .secondary)
        case .waitingForSummaries:
            pill("Waiting for a summary provider", .secondary)
        case .needsAttention:
            pill("Needs attention", .orange)
        case .needsKey(let provider):
            Button { reveal(provider) } label: { pill("No API key yet · Add it", .orange) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens this provider’s account below.")
        case .nothingToRead:
            pill("Nothing to read yet", .orange)
        case .verified(let text):
            pill(LocalizedStringKey(text), .green)
        case .unverified:
            pill("Unverified", .secondary)
        }
    }

    private func pill(_ text: LocalizedStringKey, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .overlay(Capsule().stroke(tint.opacity(0.4)))
        .fixedSize()
    }
}

/// The controls line the design gives every row: provider first, then what it
/// governs, then this row's own action. Same column proportions on all three rows.
private struct ControlLine<P: View, M: View, V: View, T: View>: View {
    @ViewBuilder let provider: P
    @ViewBuilder let model: M
    @ViewBuilder let voice: V
    @ViewBuilder let trailing: T

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Minimums, not just proportions: the voice cell carries the widest
            // text and without them it squeezes the other two into slivers. The
            // row's own action keeps its full width so it cannot be clipped off
            // the right edge.
            provider.frame(minWidth: 120, maxWidth: .infinity)
            model.frame(minWidth: 120, maxWidth: .infinity)
            voice.frame(minWidth: 170, maxWidth: .infinity).layoutPriority(1)
            trailing.fixedSize().layoutPriority(3)
        }
    }
}

/// A monospaced ID field with a click-through to the provider's list of values.
private struct IDField: View {
    let label: LocalizedStringKey
    let placeholder: String
    @Binding var text: String
    let browse: URL
    let browseHelp: LocalizedStringKey
    var identifier: String?

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, text: $text, prompt: Text(verbatim: placeholder))
                .labelsHidden().textFieldStyle(.roundedBorder)
                .font(.caption.monospaced()).autocorrectionDisabled()
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier ?? "")
            Link(destination: browse) {
                Image(systemName: "arrow.up.right.square")
            }
            .help(browseHelp)
            .accessibilityLabel(browseHelp)
        }
    }
}

private struct ProviderPicker: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let options: [VoiceProvider]
    /// A leading row for "not configured" / "same as summaries".
    var leading: (value: String, title: String)?

    var body: some View {
        Picker(label, selection: $selection) {
            if let leading { Text(verbatim: leading.title).tag(leading.value) }
            ForEach(options, id: \.rawValue) { Text($0.display).tag($0.rawValue) }
            // A stored choice this build cannot offer still needs a tag, or the
            // picker renders undefined.
            if !options.contains(where: { $0.rawValue == selection }), leading?.value != selection {
                Text(VoiceProvider(rawValue: selection)?.display ?? selection).tag(selection)
            }
        }
        .labelsHidden().accessibilityLabel(label)
    }
}

// MARK: - Voice conversation

private struct ConversationFeatureRow: View {
    let provider: VoiceProvider?
    @ObservedObject var menuModel: MenuBarModel
    /// Observed, not read through `menuModel`: `busy` gates this row's Test button.
    @ObservedObject var reader: ReadAloud
    @ObservedObject var tests: SettingsTestCoordinator
    @ObservedObject var credential: SettingsCredential
    @Binding var selection: String
    let reveal: (VoiceProvider) -> Void
    @AppStorage(VoiceSettings.companionEnabledKey) private var enabled = false
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspaceID = ""
    @AppStorage private var modelID: String
    @AppStorage private var voiceID: String

    init(provider: VoiceProvider?, menuModel: MenuBarModel, tests: SettingsTestCoordinator,
         credentials: SettingsCredentials, selection: Binding<String>, reveal: @escaping (VoiceProvider) -> Void) {
        self.provider = provider
        self.menuModel = menuModel
        self.reader = menuModel.readAloud
        self.tests = tests
        self.credential = credentials[provider ?? .qwen]
        _selection = selection
        self.reveal = reveal
        let keyed = provider ?? .qwen
        _modelID = AppStorage(wrappedValue: "", VoiceSettings.modelKey(keyed))
        _voiceID = AppStorage(wrappedValue: "", VoiceSettings.voiceKey(keyed))
    }

    private var configuration: SettingsModelTestOperations.VoiceConfiguration? {
        guard let provider else { return nil }
        let selectedLanguage = VoiceLanguage(rawValue: language) ?? .english
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(provider: provider, model: model.isEmpty ? provider.defaultModel : model,
                     voice: voice.isEmpty ? VoiceSettings.voice(provider, selectedLanguage) : voice,
                     workspace: workspace.isEmpty ? nil : workspace, international: intl)
    }
    private var detail: String? { provider == nil ? nil : configuration?.failure }
    private var status: VoiceFeatureStatus {
        guard let provider else { return .unconfigured }
        if !credential.configured { return .needsKey(provider) }
        if detail != nil { return .needsAttention }
        if tests.purpose == .voice, tests.phase == .succeeded { return .verified("Connection confirmed") }
        return .unverified
    }

    var body: some View {
        FeatureRow(feature: .conversation, enabled: $enabled, status: status,
                   detail: detail, tests: tests, reveal: reveal) {
            ControlLine {
                ProviderPicker(label: "Voice conversation provider", selection: $selection,
                               options: VoiceProvider.allCases)
            } model: {
                if let provider {
                    IDField(label: "Realtime model ID", placeholder: provider.defaultModel, text: $modelID,
                            browse: provider.modelsURL, browseHelp: "Browse available models",
                            identifier: "voiceModelID")
                } else { Text(verbatim: "—").foregroundStyle(.secondary) }
            } voice: {
                if let provider {
                    VoicePicker(label: "Conversation voice", purpose: .conversation, provider: provider,
                                language: VoiceLanguage(rawValue: language) ?? .english,
                                fallback: VoiceSettings.voice(provider,
                                    VoiceLanguage(rawValue: language) ?? .english),
                                voiceID: $voiceID)
                } else { Text(verbatim: "—").foregroundStyle(.secondary) }
            } trailing: {
                Button("Test", action: test)
                    .disabled(tests.isBusy || provider == nil || !credential.configured
                              || configuration?.failure != nil || reader.busy)
                    .help("Check the realtime connection. Billed by the provider; no microphone, task history or tools.")
            }
        }
        .onAppear { credential.refresh() }
        .onChange(of: [modelID, voiceID, language, workspaceID, String(intl),
                       String(credential.revision), String(enabled)]) { _, _ in tests.invalidate() }
        .onChange(of: enabled) { _, on in if !on { menuModel.voiceChat.companionDisabled() } }
    }

    private func test() {
        guard let configuration, credential.configured, configuration.failure == nil,
              !tests.isBusy, !reader.busy else { return }
        credential.load()
        guard credential.configured else { return tests.reportUnreadableKey(.voice) }
        let session = configuration.makeSession(apiKey: credential.value)
        tests.start(.voice, timeout: .seconds(15), operation: {
            await SettingsModelTestOperations.handshake(session: session, voice: configuration.voice)
        }, cleanup: { await session.close() })
    }
}

// MARK: - AI completion summaries

private struct SummaryFeatureRow: View {
    let provider: VoiceProvider?
    @ObservedObject var tests: SettingsTestCoordinator
    @ObservedObject var credential: SettingsCredential
    /// Read-aloud owns the speaker; a sample must not run over it.
    @ObservedObject var reader: ReadAloud
    let language: String
    @Binding var selection: String
    let reveal: (VoiceProvider) -> Void
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var enabled = false
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    @AppStorage private var modelID: String

    init(provider: VoiceProvider?, tests: SettingsTestCoordinator, credentials: SettingsCredentials,
         reader: ReadAloud, language: String, selection: Binding<String>,
         reveal: @escaping (VoiceProvider) -> Void) {
        self.provider = provider
        self.tests = tests
        self.credential = credentials[provider ?? .qwen]
        self.reader = reader
        self.language = language
        _selection = selection
        self.reveal = reveal
        let keyed = provider ?? .qwen
        _modelID = AppStorage(wrappedValue: CompletionSummaryConfiguration.recommendedModel(keyed),
                              CompletionSummaryConfiguration.modelKey(keyed))
    }

    /// Match the runtime load policy without writing defaults while browsing.
    private var effectiveModel: String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? CompletionSummaryConfiguration.recommendedModel(provider ?? .qwen) : trimmed
    }
    private var configuration: CompletionSummaryConfiguration? {
        guard let provider else { return nil }
        // An explicit sample test is independent of enabling automatic summaries.
        return .init(enabled: true, provider: provider, modelID: effectiveModel,
                     language: VoiceLanguage(rawValue: language) ?? .english,
                     qwenUseIntl: intl, qwenWorkspaceID: workspace)
    }
    private var detail: String? {
        configuration?.configurationFailure.map(SettingsModelTestOperations.summaryFailureMessage)
    }
    private var status: VoiceFeatureStatus {
        guard let provider else { return .unconfigured }
        if !credential.configured { return .needsKey(provider) }
        if detail != nil { return .needsAttention }
        if tests.purpose == .summary, tests.phase == .succeeded { return .verified("Sample generated") }
        return .unverified
    }

    var body: some View {
        FeatureRow(feature: .summaries, enabled: $enabled, status: status,
                   detail: detail, tests: tests, reveal: reveal) {
            ControlLine {
                ProviderPicker(label: "Completion summary provider", selection: $selection,
                               options: VoiceProvider.summaryProviders,
                               leading: ("", NSLocalizedString("Not configured", comment: "No summary provider")))
            } model: {
                if let provider {
                    IDField(label: "Text model ID",
                            placeholder: CompletionSummaryConfiguration.recommendedModel(provider),
                            text: $modelID, browse: provider.modelsURL,
                            browseHelp: "Browse available models", identifier: "completionSummaryModelID")
                } else { Text(verbatim: "—").foregroundStyle(.secondary) }
            } voice: {
                // Summaries are text; the voice column stays empty on purpose.
                Text(verbatim: "—").foregroundStyle(.secondary)
                    .accessibilityLabel("No voice — summaries are text")
            } trailing: {
                Button("Sample", action: test)
                    .disabled(tests.isBusy || provider == nil || configuration?.configurationFailure != nil
                              || !credential.configured || reader.busy)
                    .accessibilityIdentifier("completionSummaryTest")
                    .help("Generate one synthetic summary with this Mac’s saved key. Billed; no task history is sent.")
            }
        }
        .onAppear { credential.refresh() }
        .onChange(of: [modelID, language, workspace, String(intl),
                       String(credential.revision), String(enabled)]) { _, _ in tests.invalidate() }
    }

    private func test() {
        guard let configuration, credential.configured, configuration.configurationFailure == nil,
              !tests.isBusy, !reader.busy else { return }
        credential.load()
        guard credential.configured else { return tests.reportUnreadableKey(.summary) }
        let key = credential.value
        tests.start(.summary, timeout: .seconds(13), operation: {
            await SettingsModelTestOperations.summary(configuration: configuration, apiKey: key)
        })
    }
}

// MARK: - Read summaries aloud

private struct ReadAloudFeatureRow: View {
    let status: VoiceSettings.ReadAloudStatus
    /// What "Same as summaries" currently points at — named in the picker itself.
    let summaryProvider: VoiceProvider?
    @ObservedObject var reader: ReadAloud
    @ObservedObject var voiceChat: VoiceChat
    @ObservedObject var tests: SettingsTestCoordinator
    @ObservedObject var credential: SettingsCredential
    @Binding var selection: String
    let reveal: (VoiceProvider) -> Void
    @AppStorage(ReadAloud.enabledKey) private var enabled = false
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var summariesEnabled = false
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    @AppStorage private var modelID: String
    @AppStorage private var voiceID: String

    init(status: VoiceSettings.ReadAloudStatus, summaryProvider: VoiceProvider?,
         reader: ReadAloud, voiceChat: VoiceChat,
         tests: SettingsTestCoordinator, credentials: SettingsCredentials,
         selection: Binding<String>, reveal: @escaping (VoiceProvider) -> Void) {
        self.status = status
        self.summaryProvider = summaryProvider
        self.reader = reader
        self.voiceChat = voiceChat
        self.tests = tests
        self.credential = credentials[status.provider ?? .qwen]
        _selection = selection
        self.reveal = reveal
        let keyed = status.provider ?? .qwen
        _modelID = AppStorage(wrappedValue: SpeechSynthesis.support(keyed).defaultModel,
                              VoiceSettings.readAloudModelKey(keyed))
        // Deliberately empty: a stored voice wins, and everything else is
        // decided by the language-aware fallback below.
        _voiceID = AppStorage(wrappedValue: "", VoiceSettings.readAloudVoiceKey(keyed))
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
    private var configuration: SpeechSynthesisConfiguration {
        let value = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(provider: status.provider ?? .qwen,
                     model: modelID.trimmingCharacters(in: .whitespacesAndNewlines), voice: effectiveVoice,
                     qwenWorkspaceID: value.isEmpty ? nil : value, qwenUseIntl: intl)
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
    private var rowStatus: VoiceFeatureStatus {
        switch status {
        case .waitingForSummaryProvider: return .waitingForSummaries
        case .ready(let provider):
            if !credential.configured { return .needsKey(provider) }
            if !summariesEnabled { return .nothingToRead }
            if tests.purpose == .readAloud, tests.phase == .succeeded { return .verified("Preview played") }
            return .unverified
        }
    }
    /// The follow option names its target, so the collapsed picker still says
    /// which vendor will speak.
    private var followTitle: String {
        let target = summaryProvider?.display ?? NSLocalizedString("not set", comment: "No summary provider")
        return String(format: NSLocalizedString("Same as summaries · %@", comment: "Read-aloud follows summaries"), target)
    }
    /// One line under the row: what "Same as summaries" currently resolves to.
    private var hint: LocalizedStringKey {
        if !summariesEnabled {
            return "Turn on AI completion summaries first — this only ever speaks that summary."
        }
        guard let provider = status.provider else { return VoiceFeature.readAloud.hint }
        return selection == provider.rawValue
            ? "Speaks through \(provider.display), whatever summaries use. Each reading is billed by the provider."
            : "Follows the completion summary provider, currently \(provider.display). Each reading is billed by the provider."
    }

    var body: some View {
        FeatureRow(feature: .readAloud, dependsOnPrevious: true, enabled: $enabled,
                   status: rowStatus, hint: hint, tests: tests, reveal: reveal) {
          VStack(alignment: .leading, spacing: 6) {
            ControlLine {
                ProviderPicker(label: "Read-aloud provider", selection: $selection,
                               options: VoiceProvider.allCases,
                               leading: ("", followTitle))
            } model: {
                if case .ready(let provider) = status {
                    IDField(label: "Speech synthesis model",
                            placeholder: SpeechSynthesis.support(provider).defaultModel,
                            text: $modelID, browse: provider.modelsURL,
                            browseHelp: "Browse available models", identifier: "readAloudModelID")
                } else { Text(verbatim: "—").foregroundStyle(.secondary) }
            } voice: {
                if case .ready(let provider) = status {
                    VoicePicker(label: "Read-aloud voice", purpose: .readAloud, provider: provider,
                                language: VoiceLanguage(rawValue: language) ?? .english,
                                fallback: VoiceSettings.readAloudVoice(provider, language: spokenLanguage),
                                voiceID: $voiceID) {
                        Button(action: preview) {
                            Image(systemName: isPreviewing ? "stop.fill" : "play.fill")
                        }
                        // While this row owns the test the button *is* Stop, so it
                        // stays enabled — `reader.busy` is true for the whole preview.
                        .disabled(isPreviewing ? false
                                  : (previewFailure != nil || reader.busy || tests.isBusy))
                        .help(isPreviewing ? "Stop the preview."
                              : (previewFailure.map { LocalizedStringKey($0) }
                                 ?? "Play one sample line. This calls the provider and is billed."))
                        .accessibilityLabel("Preview the read-aloud voice")
                        .accessibilityIdentifier("readAloudPreview")
                    }
                } else { Text(verbatim: "—").foregroundStyle(.secondary) }
            } trailing: {
                // No trailing button: the ▶ beside the voice is this row's verification.
                EmptyView()
            }
            // A reading that started on its own is stoppable here; the ▶ owns previews only.
            if reader.automaticBusy || !reader.status.isEmpty {
                HStack(spacing: 8) {
                    Text(reader.automaticBusy && tests.purpose == .readAloud && tests.isBusy
                         ? "Automatic reading is queued until the preview finishes."
                         : LocalizedStringKey(reader.status))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Stop automatic reading") { reader.stopAutomaticReading() }
                        .disabled(!reader.automaticBusy)
                        .controlSize(.small)
                }
            }
          }
        }
        .onAppear { credential.refresh() }
        .onChange(of: [modelID, voiceID, workspace, String(intl), String(credential.revision),
                       String(enabled)]) { _, _ in tests.invalidate() }
        .onChange(of: enabled) { _, on in if !on { reader.stop() } }
        .onChange(of: [modelID, voiceID]) { _, _ in reader.stop() }
        .onChange(of: voiceChat.isActive) { _, active in
            if active, tests.purpose == .readAloud { tests.cancel() }
        }
    }

    /// This row owns the running test, so its button reads and acts as Stop.
    private var isPreviewing: Bool { tests.purpose == .readAloud && tests.isBusy }

    private func preview() {
        if isPreviewing { tests.cancel(); return }
        guard previewFailure == nil, !tests.isBusy, !reader.busy else { return }
        credential.load()
        guard credential.configured else { return tests.reportUnreadableKey(.readAloud) }
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

// MARK: - Provider accounts

/// One provider's credentials, in the only place on the page that holds them.
private struct AccountRow: View {
    let provider: VoiceProvider
    @ObservedObject var credential: SettingsCredential
    @ObservedObject var tests: SettingsTestCoordinator
    let usedBy: [VoiceFeature]
    @Binding var expanded: Bool
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspaceID = ""

    private var keyInput: Binding<String> {
        Binding(get: { credential.value }, set: { credential.edit($0); tests.invalidate() })
    }
    private var usage: String {
        usedBy.isEmpty
            ? NSLocalizedString("Not used by any feature", comment: "Idle provider account")
            : String(format: NSLocalizedString("Used by %@", comment: "Which features use this account"),
                     usedBy.map { NSLocalizedString($0.rawValue, comment: "Feature name") }
                        .formatted(.list(type: .and)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.display)
                    Text(verbatim: usage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if credential.saveFailed {
                    Text("Key not saved").font(.caption).foregroundStyle(.orange)
                } else if credential.configured {
                    Text("Key saved").font(.caption).foregroundStyle(.green)
                } else {
                    Text("No key").font(.caption).foregroundStyle(.secondary)
                }
                Button(expanded ? "Done" : (credential.configured ? "Edit" : "Add key")) {
                    expanded.toggle()
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        SecureField("API key", text: keyInput,
                                    prompt: Text("Paste your \(provider.display) key"))
                            .labelsHidden().textFieldStyle(.roundedBorder).autocorrectionDisabled()
                            .accessibilityLabel("API key")
                            .accessibilityIdentifier("apiKey-\(provider.rawValue)")
                        Button {
                            guard let pasted = NSPasteboard.general.string(forType: .string)?
                                .trimmingCharacters(in: .whitespacesAndNewlines), !pasted.isEmpty else { return }
                            keyInput.wrappedValue = pasted
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard").labelStyle(.iconOnly)
                        }
                        .help("Paste")
                        .accessibilityIdentifier("paste-apiKey-\(provider.rawValue)")
                    }
                    if credential.saveFailed {
                        Text("API key could not be saved. Your edit is not stored; edit or paste it again to retry.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if provider == .qwen {
                        Toggle("Use Singapore (international) region", isOn: $intl)
                        HStack(spacing: 6) {
                            TextField("Workspace ID", text: $workspaceID,
                                      prompt: Text(verbatim: "optional · llm-xxxxxxxx"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                                .font(.caption.monospaced()).autocorrectionDisabled()
                                .accessibilityLabel("Workspace ID")
                                .accessibilityIdentifier("qwenWorkspaceID")
                            Link(destination: VoiceProvider.qwenWorkspaceIDURL) {
                                Image(systemName: "arrow.up.right.square")
                            }
                            .help("Find your workspace ID")
                        }
                        Text("Optional. When set, Qwen connects through the workspace endpoint.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Link("Get an API key", destination: provider.apiKeyURL).font(.caption)
                        Spacer(minLength: 8)
                        Text("Kept in the Keychain, once per provider.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 3)
        .onAppear { credential.refresh() }
        .onChange(of: expanded) { _, open in if open { credential.load() } }
        .onChange(of: [String(intl), workspaceID]) { _, _ in tests.invalidate() }
    }
}
