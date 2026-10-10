import Foundation
import Testing
@testable import VibeBuddyKit

struct JapaneseSpeechTests {
    @Test func japaneseReadingReplacesIncompatiblePresetsWithoutChangingChatOrCustomVoices() throws {
        let name = "japanese-speech-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("zh", forKey: VoiceSettings.conversationLanguageKey)
        defaults.set("ja", forKey: VoiceSettings.summaryLanguageKey)
        for provider in [VoiceProvider.qwen, .doubao, .gemini, .minimax] {
            let support = try #require(SpeechSynthesis.support(provider))
            defaults.set(support.defaultVoice, forKey: VoiceSettings.readAloudVoiceKey(provider))
            let config = VoiceSettings.readAloudConfiguration(provider, defaults: defaults)
            #expect(config.language == .japanese)
            let voice = try #require(VoiceCatalog.voices(.readAloud, provider).first { $0.id == config.effectiveVoice })
            #expect(voice.speaks(.japanese))
            #expect(VoiceSettings.conversationLanguage(defaults: defaults) == .chinese)
            if provider == .qwen { #expect(config.effectiveModel == "qwen-audio-3.1-tts-flash") }
            defaults.set("custom-voice", forKey: VoiceSettings.readAloudVoiceKey(provider))
            #expect(VoiceSettings.readAloudConfiguration(provider, defaults: defaults).voice == "custom-voice")
        }
    }

    @Test func japaneseLanguageReachesVendorParametersWithoutChangingChineseRequests() throws {
        let qwen = QwenSpeechSynthesizer(workspaceID: nil, useIntl: false, language: .japanese).parameters()
        #expect(qwen["language_hints"] as? [String] == ["ja"])
        let doubao = DoubaoSpeechSynthesizer(persona: VoiceStyle.serious.persona(.japanese), language: .japanese)
            .requestBody("作業が完了しました。")
        let params = try #require(doubao["req_params"] as? [String: Any])
        let json = try #require(params["additions"] as? String)
        let additions = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(additions["explicit_language"] as? String == "ja")
        #expect(additions["context_texts"] as? [String] == [VoiceStyle.serious.persona(.japanese)!.cue])
        #expect(MiniMaxSpeechSynthesizer(language: .japanese).requestBody("報告です。")["language_boost"] as? String == "Japanese")
        #expect(MiniMaxSpeechSynthesizer(language: .chinese).requestBody("报告")["language_boost"] == nil)
    }

    @Test func speechLanguageSurvivesTheWireAndOldClientsRemainCompatible() throws {
        let request = ContentPresentationRequest(sourceID: "mac", target: .completion(sessionID: "s", completionID: "c"), language: .japanese)
        #expect(try JSONDecoder().decode(ContentPresentationRequest.self, from: JSONEncoder().encode(request)) == request)
        let old = ContentPresentationRequest(sourceID: "mac", target: request.target)
        #expect(try JSONDecoder().decode(ContentPresentationRequest.self, from: JSONEncoder().encode(old)).language == nil)
    }
}
