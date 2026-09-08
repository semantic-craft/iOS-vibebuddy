import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct SettingsPurposeCard: View {
    let purpose: SettingsVoicePurpose
    let selected: Bool
    let provider: VoiceProvider?
    let credentials: SettingsCredentials
    @ObservedObject var tests: SettingsTestCoordinator
    let select: () -> Void
    @AppStorage(CompletionSummaryConfiguration.enabledKey) private var summaryEnabled = false
    var body: some View {
        if let provider {
            ConfiguredPurposeCard(purpose: purpose, selected: selected, provider: provider,
                credential: credentials[provider], tests: tests, select: select)
        } else {
            PurposeCardButton(purpose: purpose, selected: selected, enabled: summaryEnabled,
                detail: "", status: "Not configured", select: select)
        }
    }
}
private struct ConfiguredPurposeCard: View {
    let purpose: SettingsVoicePurpose
    let selected: Bool
    let provider: VoiceProvider
    @ObservedObject var credential: SettingsCredential
    @ObservedObject var tests: SettingsTestCoordinator
    let select: () -> Void
    @AppStorage private var model: String
    @AppStorage private var enabled: Bool
    @AppStorage(VoiceSettings.conversationLanguageKey) private var language = VoiceLanguage.english.rawValue
    @AppStorage(VoiceSettings.regionIntlKey) private var intl = false
    @AppStorage(VoiceSettings.qwenWorkspaceIDKey) private var workspace = ""
    init(purpose: SettingsVoicePurpose, selected: Bool, provider: VoiceProvider,
         credential: SettingsCredential, tests: SettingsTestCoordinator, select: @escaping () -> Void) {
        self.purpose = purpose; self.selected = selected; self.provider = provider
        self.credential = credential; self.tests = tests; self.select = select
        _model = AppStorage(wrappedValue: "", purpose == .conversation ? VoiceSettings.modelKey(provider) : CompletionSummaryConfiguration.modelKey(provider))
        _enabled = AppStorage(wrappedValue: false, purpose == .conversation ? VoiceSettings.companionEnabledKey : CompletionSummaryConfiguration.enabledKey)
    }
    private var effectiveModel: String {
        purpose == .conversation ? (model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? provider.defaultModel : model)
            : CompletionSummarySettingsSection.effectiveModelID(model, provider: provider)
    }
    private var status: LocalizedStringKey {
        if credential.saveFailed { return "API key not saved" }
        if !credential.loaded { return "Checking saved configuration…" }
        if !credential.configured { return "API key required" }
        if purpose == .summary {
            let config = CompletionSummaryConfiguration(enabled: true, provider: provider, modelID: effectiveModel,
                language: VoiceLanguage(rawValue: language) ?? .english, qwenUseIntl: intl, qwenWorkspaceID: workspace)
            if config.configurationFailure != nil { return "Review the text model or Qwen connection" }
        }
        let expected: SettingsTestCoordinator.Purpose = purpose == .conversation ? .voice : .summary
        if selected, tests.purpose == expected && tests.phase == .succeeded {
            return purpose == .conversation ? "Realtime connection confirmed" : "Sample summary generated"
        }
        return "Configuration entered · unverified"
    }
    var body: some View {
        let modelLabel = provider == .doubao && effectiveModel == provider.defaultModel
            ? NSLocalizedString("Doubao realtime voice 3.0 · Recommended", comment: "Default model label") : effectiveModel
        PurposeCardButton(purpose: purpose, selected: selected, enabled: enabled,
            detail: "\(provider.display) · \(modelLabel)", status: status, select: select)
            .onAppear { credential.load() }
    }
}
private struct PurposeCardButton: View {
    let purpose: SettingsVoicePurpose
    let selected: Bool
    let enabled: Bool
    let detail: String
    let status: LocalizedStringKey
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Image(systemName: purpose.symbol)
                    Text(LocalizedStringKey(purpose.rawValue)).font(.headline)
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                }
                Text(purpose.explanation).font(.callout)
                Text(verbatim: detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(detail)
                Label(enabled ? "Enabled" as LocalizedStringKey : "Off", systemImage: enabled ? "power.circle.fill" : "power.circle")
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading).padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(purpose.rawValue))
        .accessibilityValue(Text(enabled ? "Enabled" as LocalizedStringKey : "Off") + Text(". ") + Text(status))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Select to edit. The enable switch is separate.")
    }
}
