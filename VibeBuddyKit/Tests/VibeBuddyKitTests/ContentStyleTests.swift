import Foundation
import Testing
@testable import VibeBuddyKit

struct ContentStyleTests {
    @Test func globalPreferenceAndFingerprintFollowEffectivePrompt() throws {
        let name = "content-style-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ContentStyleConfiguration.load(defaults: defaults) == .default)
        defaults.set("custom", forKey: ContentStyleConfiguration.defaultsKey)
        defaults.set("  Explain the next action.  ", forKey: ContentStyleConfiguration.customPromptKey)
        let custom = ContentStyleConfiguration.load(defaults: defaults)
        #expect(custom == .init(style: .custom, customPrompt: "Explain the next action."))
        #expect(custom.fingerprint != ContentStyleConfiguration(style: .custom, customPrompt: "Explain the benefit.").fingerprint)
        #expect(ContentStyleConfiguration(style: .concise, customPrompt: "unused").fingerprint == ContentStyleConfiguration.default.fingerprint)
        #expect(ContentStyleConfiguration(style: .decision).fingerprint != ContentStyleConfiguration.default.fingerprint)
        #expect(!ContentStyleConfiguration(style: .custom, customPrompt: String(repeating: "字", count: 3000)).isValid)
        #expect(!ContentStyleConfiguration(style: .custom, customPrompt: " ").isValid)
        #expect(custom.isValid)
        #expect(try JSONDecoder().decode(ContentStyleConfiguration.self, from: JSONEncoder().encode(custom)) == custom)
    }
}
