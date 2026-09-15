import Foundation
import VibeBuddyKit

enum PhoneReadAloudSelection: Equatable {
    case system
    case provider(VoiceProvider)

    static let defaultsKey = "phone.readAloud.selection"

    var rawValue: String {
        switch self { case .system: "system"; case .provider(let provider): provider.rawValue }
    }

    var title: String {
        switch self { case .system: String(localized: "System speech"); case .provider(let provider): provider.display }
    }

    init(rawValue: String) {
        if let provider = VoiceProvider(rawValue: rawValue), SpeechSynthesis.support(provider) != nil {
            self = .provider(provider)
        } else { self = .system }
    }

    static func load(defaults: UserDefaults = .standard,
                     hasKey: (VoiceProvider) -> Bool = { $0.hasAPIKey }) -> Self {
        if let stored = defaults.string(forKey: defaultsKey) { return Self(rawValue: stored) }
        let previous = VoiceProvider(rawValue: defaults.string(forKey: VoiceSettings.providerKey) ?? "") ?? .qwen
        let selection: Self = SpeechSynthesis.support(previous) != nil && hasKey(previous) ? .provider(previous) : .system
        defaults.set(selection.rawValue, forKey: defaultsKey)
        return selection
    }
}
