import CryptoKit
import Foundation

public enum ContentStyle: String, Codable, CaseIterable, Sendable, Hashable {
    case concise, decision, custom

    public var title: String {
        switch self {
        case .concise: "Concise"
        case .decision: "Decision briefing"
        case .custom: "Custom prompt"
        }
    }

    public var detail: String {
        switch self {
        case .concise: "Leads with what the record asks you to do, otherwise the key result; at most one next step."
        case .decision: "A CEO briefing on progress, benefits, important tradeoffs, and decisions."
        case .custom: "Use your own instructions to shape every summary."
        }
    }
}

public struct ContentStyleConfiguration: Codable, Hashable, Sendable {
    public var style: ContentStyle
    public var customPrompt: String
    public static let maximumCustomPromptCharacters = 2000
    public static let defaultsKey = "contentStyle"
    public static let customPromptKey = "contentStyleCustomPrompt"
    public static let `default` = Self()

    public init(style: ContentStyle = .concise, customPrompt: String = "") {
        self.style = style
        self.customPrompt = customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func load(defaults: UserDefaults = .standard) -> Self {
        Self(style: ContentStyle(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .concise,
             customPrompt: defaults.string(forKey: customPromptKey) ?? "")
    }

    public var isValid: Bool {
        style != .custom || (!customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && customPrompt.count <= Self.maximumCustomPromptCharacters)
    }

    public var fingerprint: String {
        let prompt = style == .custom ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let fields = ["content-prompt-v2", style.rawValue, prompt]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SummaryPurpose: String, Codable, Sendable, Hashable {
    case notice, speech
}
