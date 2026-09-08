import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Independent voice and completion summary selection")
struct VoicePurposeSettingsTests {
    @Test func preservesValidLegacySummaryBeforeVoiceChanges() throws {
        let name = "voice-purpose-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openai", forKey: VoiceSettings.providerKey)
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == .openai)
        VoiceSettings.selectVoiceProvider(.doubao, defaults: defaults)
        #expect(defaults.string(forKey: VoiceSettings.providerKey) == "doubao")
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == .openai)
        defaults.set("gemini", forKey: VoiceSettings.summaryProviderKey)
        VoiceSettings.selectVoiceProvider(.qwen, defaults: defaults)
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == .gemini)
    }

    @Test func missingInvalidOrRealtimeOnlyDoesNotBecomeQwen() throws {
        let name = "voice-purpose-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for old in [nil, "", "unknown", "doubao"] as [String?] {
            defaults.removePersistentDomain(forName: name)
            defaults.set(old, forKey: VoiceSettings.providerKey)
            #expect(VoiceSettings.summaryProvider(defaults: defaults) == nil)
            VoiceSettings.selectVoiceProvider(.qwen, defaults: defaults)
            #expect(VoiceSettings.summaryProvider(defaults: defaults) == nil)
        }
        #expect(!VoiceProvider.summaryProviders.contains(.doubao))
        #expect(VoiceProvider.doubao.keychainAccount != VoiceProvider.qwen.keychainAccount)
    }
}
