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

    /// The mirror of Doubao: a vendor that summarizes but cannot speak. It has
    /// to stay out of the realtime path even if a stored default names it.
    @Test func aTextOnlyProviderSummarizesButIsNeverTheVoiceProvider() throws {
        #expect(VoiceProvider.summaryProviders.contains(.deepseek))
        #expect(!VoiceProvider.voiceProviders.contains(.deepseek))
        #expect(VoiceProvider.voiceProviders.contains(.doubao))
        #expect(VoiceProvider.deepseek.keychainAccount == "deepseek.apiKey")
        #expect(Set(VoiceProvider.allCases.map(\.keychainAccount)).count == VoiceProvider.allCases.count)

        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: VoiceSettings.providerKey)
        defer {
            if let saved { defaults.set(saved, forKey: VoiceSettings.providerKey) }
            else { defaults.removeObject(forKey: VoiceSettings.providerKey) }
        }
        defaults.set(VoiceProvider.deepseek.rawValue, forKey: VoiceSettings.providerKey)
        #expect(VoiceSettings.provider == .qwen)
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
        // Following means following, whichever vendor summaries picked.
        defaults.set("openai", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.openai))
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
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.openai))
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

    @Test func everyVoiceProviderCanReadAloud() throws {
        // Doubao stays out of summaries, but read-aloud is a separate question:
        // it speaks, so it can be picked here — only never inherited.
        #expect(!VoiceProvider.summaryProviders.contains(.doubao))
        for provider in VoiceProvider.voiceProviders {
            let support = try #require(SpeechSynthesis.support(provider), "\(provider) speech support")
            #expect(!support.defaultModel.isEmpty, "\(provider) model")
            #expect(!support.defaultVoice.isEmpty, "\(provider) voice")
        }
        // The other direction: a text-only vendor has no speech API to hand out.
        #expect(SpeechSynthesis.support(.deepseek) == nil)
        #expect(SpeechSynthesis.synthesizer(.init(provider: .deepseek, model: "deepseek-flash", voice: "")) == nil)
    }

    @Test func readAloudReportsATextOnlySummaryProviderInsteadOfFollowingIt() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(VoiceProvider.deepseek.rawValue, forKey: VoiceSettings.summaryProviderKey)
        // Following a text-only summary provider is its own state, not Qwen.
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == .deepseek)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .summaryProviderCannotSpeak(.deepseek))
        #expect(VoiceSettings.readAloudStatus(defaults: defaults).provider == nil)
        // It cannot be pinned either, by picker or by a hand-edited default.
        VoiceSettings.selectReadAloudProvider(.deepseek, defaults: defaults)
        #expect(VoiceSettings.pinnedReadAloudProvider(defaults: defaults) == nil)
        defaults.set(VoiceProvider.deepseek.rawValue, forKey: VoiceSettings.readAloudProviderKey)
        #expect(VoiceSettings.pinnedReadAloudProvider(defaults: defaults) == nil)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .summaryProviderCannotSpeak(.deepseek))
        // Pinning a vendor that speaks still works while summaries stay text-only.
        VoiceSettings.selectReadAloudProvider(.qwen, defaults: defaults)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
    }
}
