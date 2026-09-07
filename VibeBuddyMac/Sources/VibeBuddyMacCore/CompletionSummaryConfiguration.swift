import Foundation
import VibeBuddyKit

/// A separate opt-in and text model; never falls back to a realtime model.
public struct CompletionSummaryConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var provider: VoiceProvider
    public var modelID: String
    public var language: VoiceLanguage
    public var qwenUseIntl: Bool
    public var qwenWorkspaceID: String?

    public init(enabled: Bool = false, provider: VoiceProvider = .qwen, modelID: String = "",
                language: VoiceLanguage = .english, qwenUseIntl: Bool = false,
                qwenWorkspaceID: String? = nil) {
        self.enabled = enabled
        self.provider = provider
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
        self.qwenUseIntl = qwenUseIntl
        let workspace = qwenWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.qwenWorkspaceID = workspace?.isEmpty == false ? workspace : nil
    }

    public static func recommendedModel(_ provider: VoiceProvider) -> String { provider == .qwen ? "qwen3.8-flash" : "" }

    public static let enabledKey = "completionSummaryEnabled"
    public static func modelKey(_ provider: VoiceProvider) -> String { "completionSummaryModel.\(provider.rawValue)" }

    /// Reads only known preferences; UI owns writes. Keychain is read only when a request can start.
    public static func load(defaults: UserDefaults = .standard) -> Self {
        let provider = VoiceProvider(rawValue: defaults.string(forKey: VoiceSettings.providerKey) ?? "") ?? .qwen
        return Self(enabled: defaults.bool(forKey: enabledKey), provider: provider,
                    modelID: defaults.string(forKey: modelKey(provider)).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? recommendedModel(provider),
                    language: VoiceLanguage(rawValue: defaults.string(forKey: VoiceSettings.conversationLanguageKey) ?? "") ?? .english,
                    qwenUseIntl: defaults.bool(forKey: VoiceSettings.regionIntlKey),
                    qwenWorkspaceID: defaults.string(forKey: VoiceSettings.qwenWorkspaceIDKey))
    }

    public var configurationFailure: CompletionSummaryFailure? {
        if !enabled { return .disabled }
        if modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .missingModel }
        // Model IDs are data except in Gemini's path. Reject URL delimiters rather than accepting a different endpoint.
        if !modelID.utf8.allSatisfy({ Self.identifierBytes.contains($0) }), provider == .gemini { return .invalidModel }
        if provider == .qwen, let workspace = qwenWorkspaceID,
           workspace.isEmpty || workspace.count > 63 || workspace.first == "-" || workspace.last == "-"
            || !workspace.utf8.allSatisfy({ Self.hostLabelBytes.contains($0) }) { return .invalidWorkspace }
        return nil
    }

    private static let hostLabelBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
    private static let identifierBytes = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".utf8)
}
