import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Voice catalog and its tier rule")
struct VoiceCatalogTests {
    @Test func eachPurposeHasItsOwnSetForTheSameVendor() {
        // OpenAI's speech list adds three voices its realtime list does not have.
        let talk = Set(VoiceCatalog.voices(.conversation, .openai).map(\.id))
        let read = Set(VoiceCatalog.voices(.readAloud, .openai).map(\.id))
        #expect(talk.count == 10)
        #expect(read.count == 13)
        #expect(read.subtracting(talk) == ["fable", "nova", "onyx"])
        // Doubao's realtime and TTS families do not even share ID shapes.
        #expect(VoiceCatalog.voices(.conversation, .doubao).contains { $0.id.contains("_jupiter_") })
        #expect(!VoiceCatalog.voices(.readAloud, .doubao).contains { $0.id.contains("_jupiter_") })
        // Every (purpose, provider) is populated.
        for purpose in VoicePurpose.allCases {
            for provider in VoiceProvider.allCases {
                #expect(!VoiceCatalog.voices(purpose, provider).isEmpty, "\(purpose) \(provider)")
            }
        }
    }

    @Test func tierRuleTurnsOnJustAboveTheLimit() {
        // Qwen read-aloud sits below the limit; Doubao and Gemini above it.
        #expect(VoiceCatalog.voices(.readAloud, .qwen).count <= VoiceCatalog.tierLimit)
        #expect(!VoiceCatalog.isTiered(.readAloud, .qwen))
        #expect(VoiceCatalog.voices(.readAloud, .doubao).count > VoiceCatalog.tierLimit)
        #expect(VoiceCatalog.isTiered(.readAloud, .doubao))
        #expect(VoiceCatalog.isTiered(.readAloud, .gemini))
        // Below the limit the dropdown holds everything in the language;
        // above it, only the vendor's own recommended tier.
        let qwen = VoiceCatalog.shortlist(.readAloud, .qwen, language: .chinese)
        #expect(qwen.count == VoiceCatalog.voices(.readAloud, .qwen).filter { $0.speaks(.chinese) }.count)
        let doubao = VoiceCatalog.shortlist(.readAloud, .doubao, language: .chinese)
        #expect(doubao.allSatisfy { $0.isCore })
        #expect(doubao.count < VoiceCatalog.voices(.readAloud, .doubao).count)
    }

    @Test func theLanguageFilterNeverEmptiesTheList() {
        // Qwen's realtime voices are all Chinese, so English has nothing to match.
        #expect(VoiceCatalog.voices(.conversation, .qwen).allSatisfy { $0.language == .chinese })
        let english = VoiceCatalog.shortlist(.conversation, .qwen, language: .english)
        #expect(english.count == VoiceCatalog.voices(.conversation, .qwen).count)
        // And no (purpose, provider, language) combination comes back empty.
        for purpose in VoicePurpose.allCases {
            for provider in VoiceProvider.allCases {
                for language in [VoiceLanguage.english, .chinese] {
                    #expect(!VoiceCatalog.shortlist(purpose, provider, language: language).isEmpty,
                            "\(purpose) \(provider) \(language)")
                }
            }
        }
    }

    @Test func qwenEnglishReadAloudVoicesAreOfferedInEnglish() {
        let english = VoiceCatalog.shortlist(.readAloud, .qwen, language: .english)
        #expect(english.map(\.id) == ["loongmary", "loongeva_v3.6", "loongjohn"])
        // The hard-coded trio this replaces was Chinese-only, which is the bug.
        #expect(english.allSatisfy { $0.language == .english })
    }

    @Test func platformIPVoicesAreAbsentFromTheCatalog() {
        // Volcengine's 抖音同款 / 剪映同款 / 豆包同款 / 番茄小说同款 tier.
        let tagged = ["zh_female_peiqi_uranus_bigtts", "zh_male_silang_uranus_bigtts",
                      "zh_male_qingcang_uranus_bigtts", "zh_female_zhishuaiyingzi_uranus_bigtts"]
        let everything = VoicePurpose.allCases.flatMap { purpose in
            VoiceProvider.allCases.flatMap { VoiceCatalog.voices(purpose, $0) }
        }
        for id in tagged { #expect(!everything.contains { $0.id == id }, "\(id)") }
    }

    @Test func groupingKeepsTheVendorsOrderAndSearchLooksEverywhere() {
        let doubao = VoiceCatalog.voices(.readAloud, .doubao)
        let groups = VoiceCatalog.grouped(doubao)
        #expect(groups.first?.category == "通用场景")
        #expect(groups.map(\.voices).reduce(0) { $0 + $1.count } == doubao.count)
        #expect(VoiceCatalog.search("british", in: VoiceCatalog.voices(.readAloud, .qwen)).map(\.id) == ["loongmary"])
        #expect(VoiceCatalog.search("  ", in: doubao).count == doubao.count)
        #expect(VoiceCatalog.search("no such voice", in: doubao).isEmpty)
    }
}

@Suite("Runtime defaults exist in the catalog")
struct VoiceDefaultsInCatalogTests {
    @Test func everyRealtimeDefaultIsACatalogVoice() {
        for provider in VoiceProvider.allCases {
            let ids = Set(VoiceCatalog.voices(.conversation, provider).map(\.id))
            for language in [VoiceLanguage.english, .chinese] {
                let fallback = provider.defaultVoice(language)
                #expect(ids.contains(fallback), "\(provider) \(language) → \(fallback)")
            }
        }
    }

    @Test func everySynthesisDefaultIsACatalogVoice() {
        for provider in VoiceProvider.allCases {
            guard let support = SpeechSynthesis.support(provider) else { continue }
            let ids = Set(VoiceCatalog.voices(.readAloud, provider).map(\.id))
            #expect(ids.contains(support.defaultVoice), "\(provider) → \(support.defaultVoice)")
        }
    }
}

@Suite("A fresh conversation voice follows the language")
struct ConversationDefaultVoiceTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "conversation-voice-\(UUID())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func doubaoEnglishNoLongerStartsOnAChineseVoice() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // The bug: Vivi is Chinese-only, and the vendor constant handed her out
        // whatever the conversation language was.
        #expect(VoiceProvider.doubao.defaultVoice(.english) == "zh_female_vv_jupiter_bigtts")
        let english = VoiceSettings.voice(.doubao, .english, defaults: defaults)
        #expect(VoiceCatalog.voices(.conversation, .doubao).first { $0.id == english }?.language == .english)
        #expect(VoiceSettings.voice(.doubao, .chinese, defaults: defaults) == "zh_female_vv_jupiter_bigtts")
    }

    @Test func aCuratedVoiceThatSpeaksTheLanguageIsKept() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // Gemini's voices are multilingual, so its own language branch stands —
        // the catalog corrects the language, it does not overrule the taste.
        #expect(VoiceSettings.voice(.gemini, .english, defaults: defaults) == "Puck")
        #expect(VoiceSettings.voice(.gemini, .chinese, defaults: defaults) == "Aoede")
        #expect(VoiceSettings.voice(.openai, .chinese, defaults: defaults) == "marin")
        // Qwen's realtime voices are Chinese-only, so English has nothing better.
        #expect(VoiceSettings.voice(.qwen, .english, defaults: defaults) == "longanqian")
    }

    @Test func aStoredVoiceOutranksTheLanguage() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("S_MyClonedVoice_42", forKey: VoiceSettings.voiceKey(.doubao))
        #expect(VoiceSettings.voice(.doubao, .english, defaults: defaults) == "S_MyClonedVoice_42")
    }

    @Test func everyProviderAndLanguageResolvesToACatalogVoice() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        for provider in VoiceProvider.allCases {
            for language in [VoiceLanguage.english, .chinese] {
                let id = VoiceSettings.voice(provider, language, defaults: defaults)
                let voice = VoiceCatalog.voices(.conversation, provider).first { $0.id == id }
                #expect(voice != nil, "\(provider) \(language) → \(id)")
                // And it is never a voice documented as speaking another one.
                #expect(voice?.speaks(language) == true
                        || VoiceCatalog.voices(.conversation, provider).allSatisfy { !$0.speaks(language) },
                        "\(provider) \(language) → \(id)")
            }
        }
    }

    /// The picker's shortlist and the voice the session actually opens with must
    /// agree, or the row shows one voice and the call speaks another.
    @Test func theShortlistLeadsWithTheVoiceTheSessionWillUse() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        for provider in VoiceProvider.allCases {
            for language in [VoiceLanguage.english, .chinese] {
                let id = VoiceSettings.voice(provider, language, defaults: defaults)
                #expect(VoiceCatalog.shortlist(.conversation, provider, language: language)
                    .contains { $0.id == id }, "\(provider) \(language) → \(id)")
            }
        }
    }
}

@Suite("A fresh read-aloud voice follows the language")
struct ReadAloudDefaultVoiceTests {
    private func suite() throws -> (UserDefaults, String) {
        let name = "read-aloud-voice-\(UUID())"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func englishNeverStartsOnAChineseVoice() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        // Nothing stored: the language decides, not the vendor's constant.
        defaults.set(VoiceLanguage.english.rawValue, forKey: VoiceSettings.conversationLanguageKey)
        let english = VoiceSettings.readAloudVoice(.qwen, defaults: defaults)
        #expect(VoiceCatalog.voices(.readAloud, .qwen).first { $0.id == english }?.language == .english)
        defaults.set(VoiceLanguage.chinese.rawValue, forKey: VoiceSettings.conversationLanguageKey)
        let chinese = VoiceSettings.readAloudVoice(.qwen, defaults: defaults)
        #expect(VoiceCatalog.voices(.readAloud, .qwen).first { $0.id == chinese }?.language == .chinese)
        #expect(english != chinese)
    }

    @Test func aStoredVoiceOutranksTheLanguage() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(VoiceLanguage.english.rawValue, forKey: VoiceSettings.conversationLanguageKey)
        defaults.set("S_MyClonedVoice_42", forKey: VoiceSettings.readAloudVoiceKey(.qwen))
        #expect(VoiceSettings.readAloudVoice(.qwen, defaults: defaults) == "S_MyClonedVoice_42")
    }

    @Test func everyProviderAndLanguageResolvesToACatalogVoice() throws {
        let (defaults, name) = try suite()
        defer { defaults.removePersistentDomain(forName: name) }
        for provider in VoiceProvider.allCases {
            for language in [VoiceLanguage.english, .chinese] {
                let id = VoiceSettings.readAloudVoice(provider, language: language, defaults: defaults)
                #expect(VoiceCatalog.voices(.readAloud, provider).contains { $0.id == id },
                        "\(provider) \(language) → \(id)")
            }
        }
    }
}
