import CryptoKit
import Foundation
import VibeBuddyKit

/// A separate opt-in and text model; never falls back to a realtime model.
public struct CompletionSummaryConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var provider: VoiceProvider?
    public var modelID: String
    public var language: VoiceLanguage
    public var qwenUseIntl: Bool
    public var qwenWorkspaceID: String?
    public var contentStyle: ContentStyleConfiguration
    /// The reader's persona for this one request (`ContentPresentationRequest
    /// .voiceStyle`), never loaded from defaults. Deliberately outside
    /// `presentationRevision`: the phone and the Mac may read with different
    /// personas, and the revision is what both compare against the snapshot.
    public var speechStyle: VoiceStyle = .standard

    public init(enabled: Bool = false, provider: VoiceProvider? = nil, modelID: String = "",
                language: VoiceLanguage = .english, qwenUseIntl: Bool = false,
                qwenWorkspaceID: String? = nil, contentStyle: ContentStyleConfiguration = .default) {
        self.contentStyle = contentStyle
        self.enabled = enabled
        self.provider = provider
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.qwenUseIntl = qwenUseIntl
        let workspace = qwenWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.qwenWorkspaceID = workspace?.isEmpty == false ? workspace : nil
    }

    public static func recommendedModel(_ provider: VoiceProvider) -> String {
        switch provider {
        case .qwen: "qwen3.8-flash"
        case .openai: "gpt-5.6-luna"
        case .deepseek: "deepseek-flash"
        case .doubao: ""
        }
    }

    public static let enabledKey = "completionSummaryEnabled"
    public static func modelKey(_ provider: VoiceProvider) -> String { "completionSummaryModel.\(provider.rawValue)" }

    /// Reads only known preferences; UI owns writes. Keychain is read only when a request can start.
    public static func load(defaults: UserDefaults = .standard) -> Self {
        let provider = VoiceSettings.summaryProvider(defaults: defaults)
        let model = provider.map { p in
            defaults.string(forKey: modelKey(p)).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? recommendedModel(p)
        } ?? ""
        return Self(enabled: defaults.bool(forKey: enabledKey), provider: provider,
                    modelID: model,
                    language: VoiceLanguage(rawValue: defaults.string(forKey: VoiceSettings.conversationLanguageKey) ?? "") ?? .english,
                    qwenUseIntl: defaults.bool(forKey: VoiceSettings.regionIntlKey),
                    qwenWorkspaceID: defaults.string(forKey: VoiceSettings.qwenWorkspaceIDKey),
                    contentStyle: ContentStyleConfiguration.load(defaults: defaults))
    }

    public var presentationRevision: String {
        let fields = [contentStyle.fingerprint, language.rawValue, provider?.rawValue ?? "", modelID,
                      qwenUseIntl ? "intl" : "cn", qwenWorkspaceID ?? ""]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public var contentStyleStorageRevision: String {
        let fields = [presentationRevision, contentStyle.customPrompt]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func apiKey(for provider: VoiceProvider) -> String? {
        if E2ERunConfiguration.current != nil {
            let name: String
            switch provider {
            case .qwen: name = "DASHSCOPE_API_KEY"
            case .openai: name = "OPENAI_API_KEY"
            case .deepseek: name = "DEEPSEEK_API_KEY"
            case .doubao: return nil
            }
            return ProcessInfo.processInfo.environment[name]
        }
        return provider.apiKey
    }

    public var configurationFailure: CompletionSummaryFailure? {
        if !enabled { return .disabled }
        if !contentStyle.isValid { return .invalidInput }
        guard let provider, provider.supportsCompletionSummaries else { return .missingProvider }
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingModel }
        if provider == .openai, modelID.hasPrefix("gpt-live-") || modelID.hasPrefix("gpt-realtime") {
            return .invalidModel
        }
        if provider == .qwen, let workspace = qwenWorkspaceID,
           workspace.isEmpty || workspace.count > 63 || workspace.first == "-" || workspace.last == "-"
            || !workspace.utf8.allSatisfy({ Self.hostLabelBytes.contains($0) }) { return .invalidWorkspace }
        return nil
    }

    private static let hostLabelBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
}
