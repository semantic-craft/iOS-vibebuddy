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

@Suite("Read-aloud purpose provider")
struct ReadAloudPurposeSettingsTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "read-aloud-tests-\(UUID())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func followsSummariesAndNeverFallsBackToQwen() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // Nothing configured anywhere: waiting, not Qwen.
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .waitingForSummaryProvider)
        #expect(VoiceSettings.pinnedReadAloudProvider(defaults: defaults) == nil)
        // A summary provider without a synthesizer is reported, not replaced.
        defaults.set("openai", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .unsupported(.openai))
        defaults.set("qwen", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
        // An explicit "follow summaries" and a value this build cannot parse both follow.
        VoiceSettings.selectReadAloudProvider(nil, defaults: defaults)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
        defaults.set("unknown", forKey: VoiceSettings.readAloudProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
    }

    @Test func pinnedProviderStopsFollowingSummaries() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("qwen", forKey: VoiceSettings.summaryProviderKey)
        VoiceSettings.selectReadAloudProvider(.qwen, defaults: defaults)
        defaults.set("openai", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
        VoiceSettings.selectReadAloudProvider(nil, defaults: defaults)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .unsupported(.openai))
    }

    @Test func migrationMovesLegacyKeysOnceAndNeverOverwrites() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // Absent legacy keys: no side effect, and the provider default still applies.
        VoiceSettings.migrateLegacyReadAloudKeys(defaults: defaults)
        #expect(defaults.object(forKey: VoiceSettings.readAloudModelKey(.qwen)) == nil)
        // No legacy key and nothing stored: the language decides, not a constant.
        #expect(VoiceSettings.readAloudVoice(.qwen, language: .chinese, defaults: defaults)
                == QwenSpeechSynthesizer.defaultVoice)

        defaults.set("custom-model", forKey: VoiceSettings.legacyReadAloudModelKey)
        defaults.set("longanlingxi", forKey: VoiceSettings.legacyReadAloudVoiceKey)
        defaults.set("kept-voice", forKey: VoiceSettings.readAloudVoiceKey(.qwen))
        VoiceSettings.migrateLegacyReadAloudKeys(defaults: defaults)
        #expect(VoiceSettings.readAloudModel(.qwen, defaults: defaults) == "custom-model")
        #expect(VoiceSettings.readAloudVoice(.qwen, defaults: defaults) == "kept-voice")
        #expect(defaults.object(forKey: VoiceSettings.legacyReadAloudModelKey) == nil)
        #expect(defaults.object(forKey: VoiceSettings.legacyReadAloudVoiceKey) == nil)

        VoiceSettings.migrateLegacyReadAloudKeys(defaults: defaults) // Idempotent.
        #expect(VoiceSettings.readAloudModel(.qwen, defaults: defaults) == "custom-model")
        #expect(VoiceSettings.readAloudVoice(.qwen, defaults: defaults) == "kept-voice")
    }

    @Test func onlyProvidersWithASynthesizerCanReadAloud() throws {
        #expect(VoiceProvider.readAloudProviders == [.qwen])
        #expect(SpeechSynthesis.synthesizer(VoiceSettings.readAloudConfiguration(.qwen)) != nil)
        for p in VoiceProvider.allCases where !p.supportsReadAloud {
            #expect(SpeechSynthesis.synthesizer(VoiceSettings.readAloudConfiguration(p)) == nil)
        }
    }
}
