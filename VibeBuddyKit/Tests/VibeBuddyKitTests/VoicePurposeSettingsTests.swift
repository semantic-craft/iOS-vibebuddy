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
        defaults.set("deepseek", forKey: VoiceSettings.summaryProviderKey)
        VoiceSettings.selectVoiceProvider(.qwen, defaults: defaults)
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == .deepseek)
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
        defaults.set("", forKey: VoiceSettings.readAloudProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
        defaults.set("unknown", forKey: VoiceSettings.readAloudProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
    }

    @Test func pinnedProviderStopsFollowingSummaries() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("qwen", forKey: VoiceSettings.summaryProviderKey)
        defaults.set(VoiceProvider.qwen.rawValue, forKey: VoiceSettings.readAloudProviderKey)
        defaults.set("openai", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
        defaults.set("", forKey: VoiceSettings.readAloudProviderKey)
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

    @Test func readAloudReportsATextOnlySummaryProviderInsteadOfFollowingIt() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(VoiceProvider.deepseek.rawValue, forKey: VoiceSettings.summaryProviderKey)
        // Following a text-only summary provider is its own state, not Qwen.
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == .deepseek)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .summaryProviderCannotSpeak(.deepseek))
        #expect(VoiceSettings.readAloudStatus(defaults: defaults).provider == nil)
        // It cannot be pinned either: a stored text-only provider reads as no pin.
        defaults.set(VoiceProvider.deepseek.rawValue, forKey: VoiceSettings.readAloudProviderKey)
        #expect(VoiceSettings.pinnedReadAloudProvider(defaults: defaults) == nil)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .summaryProviderCannotSpeak(.deepseek))
        // Pinning a vendor that speaks still works while summaries stay text-only.
        defaults.set(VoiceProvider.qwen.rawValue, forKey: VoiceSettings.readAloudProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.qwen))
    }
}

/// Gemini was removed 2026-09-25. A user who had it selected falls back per
/// purpose without a crash and without being moved to another vendor.
@Suite("Retired Gemini settings")
struct RetiredGeminiSettingsTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "retired-gemini-tests-\(UUID())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func geminiEverywhereFallsBackPerPurpose() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("gemini", forKey: VoiceSettings.providerKey)       // summaries inherit it
        defaults.set("gemini", forKey: VoiceSettings.readAloudProviderKey)
        defaults.set(true, forKey: VoiceSettings.companionEnabledKey)
        for key in ["voiceModel.gemini", "voiceVoice.gemini", "readAloud.model.gemini",
                    "readAloud.voice.gemini", "readAloud.style.gemini", "completionSummaryModel.gemini"] {
            defaults.set("x", forKey: key)
        }
        var deleted: [String] = []
        VoiceSettings.removeRetiredGeminiSettings(defaults: defaults, keyExists: { _ in true },
                                                  deleteKey: { deleted.append($0) })

        // Conversation: default provider, companion off until the user opts in again.
        #expect(defaults.object(forKey: VoiceSettings.providerKey) == nil)
        #expect(defaults.bool(forKey: VoiceSettings.companionEnabledKey) == false)
        // Summaries: not configured, and a later voice pick does not revive anything.
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == nil)
        VoiceSettings.selectVoiceProvider(.openai, defaults: defaults)
        #expect(VoiceSettings.summaryProvider(defaults: defaults) == nil)
        // Read-aloud: follows summaries, which are unconfigured — never Qwen.
        #expect(VoiceSettings.pinnedReadAloudProvider(defaults: defaults) == nil)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .waitingForSummaryProvider)
        #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasSuffix(".gemini") })
        #expect(deleted == ["gemini.apiKey"])
        // A denied Keychain prompt must not come back at every launch.
        VoiceSettings.removeRetiredGeminiSettings(defaults: defaults, keyExists: { _ in true },
                                                  deleteKey: { deleted.append($0) })
        #expect(deleted == ["gemini.apiKey"])
    }

    @Test func otherProvidersAreUntouched() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openai", forKey: VoiceSettings.providerKey)
        defaults.set("gemini", forKey: VoiceSettings.summaryProviderKey)
        defaults.set("doubao", forKey: VoiceSettings.readAloudProviderKey)
        defaults.set(true, forKey: VoiceSettings.companionEnabledKey)
        var deleted: [String] = []
        VoiceSettings.removeRetiredGeminiSettings(defaults: defaults, keyExists: { _ in false },
                                                  deleteKey: { deleted.append($0) })
        #expect(defaults.string(forKey: VoiceSettings.providerKey) == "openai")
        #expect(defaults.bool(forKey: VoiceSettings.companionEnabledKey))
        #expect(defaults.string(forKey: VoiceSettings.summaryProviderKey) == "")
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.doubao))
        #expect(deleted.isEmpty)
    }
}
