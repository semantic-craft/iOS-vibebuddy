import Foundation
import Testing
@testable import VibeBuddyKit

/// The persona has to reach each vendor through the field that vendor's own
/// docs name, and `.standard` has to leave the request exactly as it was
/// before styles existed. Both are wire-format claims, so they are asserted
/// against the request body rather than the picker.
@Suite("Read-aloud voice style")
struct VoiceStyleTests {

    // MARK: The persona itself

    @Test func standardPullsNoLeverAndEveryPersonaPullsAllThree() {
        for language in VoiceLanguage.allCases {
            #expect(VoiceStyle.standard.persona(language) == nil)
            #expect(VoiceStyle.standard.wording(language) == nil)
            #expect(VoiceStyle.standard.previewLine(language) == nil)
            for style in VoiceStyle.allCases where style != .standard {
                let persona = style.persona(language)
                #expect(persona?.cue.contains(persona?.tone ?? "#") == true)
                #expect(style.wording(language) != nil)
                #expect(style.previewLine(language) != nil)
            }
        }
        // The listening test: Chinese personas need their own voice on both vendors.
        for style in VoiceStyle.allCases where style != .standard {
            #expect(style.voice(for: .doubao, language: .chinese) != nil)
            #expect(style.voice(for: .qwen, language: .chinese)?.model == QwenSpeechSynthesizer.styledModel)
        }
        #expect(VoiceStyle.standard.voice(for: .doubao, language: .chinese) == nil)
    }

    /// Alibaba counts each Han character as two against a 100-character cap.
    @Test func qwenSpeakerDescriptionsFitTheInstructionCap() {
        for language in VoiceLanguage.allCases {
            for style in VoiceStyle.allCases {
                guard let speaker = style.persona(language)?.speaker else { continue }
                let weight = speaker.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E7F ? 2 : 1) }
                #expect(weight <= 100, "\(style) \(language): \(weight)")
            }
        }
    }

    @Test func unparseableOrRetiredStoredStyleReadsPlainly() {
        for stored in [nil, "", "   ", "unknown", "girlNextDoor", "fieryGirl", "Sultry"] as [String?] {
            #expect(VoiceStyle(stored: stored) == .standard)
        }
        #expect(VoiceStyle(stored: " coquettish ") == .coquettish)
    }

    // MARK: Doubao — additions.context_texts, and `additions` is a jsonstring

    @Test func doubaoCarriesThePersonaInContextTextsAsAJSONString() throws {
        let persona = try #require(VoiceStyle.coquettish.persona(.chinese))
        let body = DoubaoSpeechSynthesizer(persona: persona).requestBody("摘要")
        let params = try #require(body["req_params"] as? [String: Any])
        // A jsonstring per the V3 docs — an object here is a parameter error.
        let additions = try #require(params["additions"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(additions.utf8)) as? [String: Any])
        #expect(decoded["context_texts"] as? [String] == [persona.cue])
    }

    @Test func doubaoOmitsAdditionsEntirelyWithoutAPersona() throws {
        let body = DoubaoSpeechSynthesizer().requestBody("摘要")
        let params = try #require(body["req_params"] as? [String: Any])
        #expect(params["additions"] == nil)
        #expect(params["text"] as? String == "摘要")
        #expect(params["speaker"] as? String == DoubaoSpeechSynthesizer.defaultVoice)
    }

    // MARK: Qwen — parameters.instruction, not `instructions`

    @Test func qwenCarriesThePersonaInInstruction() throws {
        let persona = try #require(VoiceStyle.sultry.persona(.chinese))
        let styled = QwenSpeechSynthesizer(workspaceID: nil, useIntl: false, persona: persona).parameters()
        #expect(styled["instruction"] as? String == persona.speaker)
        // The Qwen-TTS spelling is a different family's field; mixing them is
        // what the docs warn about.
        #expect(styled["instructions"] == nil)

        let plain = QwenSpeechSynthesizer(workspaceID: nil, useIntl: false).parameters()
        #expect(plain["instruction"] == nil)
        #expect(plain["voice"] as? String == QwenSpeechSynthesizer.defaultVoice)
    }

    /// A persona stored against one provider must not be claimed by another
    /// that would silently drop it — the setting would then be a lie.
    @Test func storedStyleIsPerProviderAndIgnoredWhereUnsupported() throws {
        let name = "voice-style-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        defaults.set(VoiceStyle.sultry.rawValue, forKey: VoiceSettings.readAloudStyleKey(.doubao))
        defaults.set(VoiceStyle.sultry.rawValue, forKey: VoiceSettings.readAloudStyleKey(.openai))
        #expect(VoiceSettings.readAloudStyle(.doubao, defaults: defaults) == .sultry)
        #expect(VoiceSettings.readAloudStyle(.openai, defaults: defaults) == .standard)
    }

    @Test func configurationCarriesStyleAndTheSpokenLanguage() throws {
        let name = "voice-style-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(VoiceStyle.coquettish.rawValue, forKey: VoiceSettings.readAloudStyleKey(.doubao))
        defaults.set("zh_female_vv_uranus_bigtts", forKey: VoiceSettings.readAloudVoiceKey(.doubao))
        // A hand-set resource the persona voice cannot use is overridden.
        defaults.set("seed-icl-2.0", forKey: VoiceSettings.readAloudModelKey(.doubao))
        defaults.set(VoiceLanguage.chinese.rawValue, forKey: VoiceSettings.conversationLanguageKey)

        let configuration = VoiceSettings.readAloudConfiguration(.doubao, defaults: defaults)
        #expect(configuration.style == .coquettish)
        #expect(configuration.language == .chinese)
        #expect(configuration.persona == VoiceStyle.coquettish.persona(.chinese))
        // The style's voice outranks the picked one; the picked one is kept for Standard.
        #expect(configuration.voice == "zh_female_vv_uranus_bigtts")
        #expect(configuration.effectiveVoice == "zh_female_sajiaoxuemei_uranus_bigtts")
        #expect(configuration.effectiveModel == DoubaoSpeechSynthesizer.defaultModel)
    }

    @Test func qwenPersonaSwitchesToTheStyledModel() {
        let styled = SpeechSynthesisConfiguration(provider: .qwen, model: QwenSpeechSynthesizer.defaultModel,
            voice: QwenSpeechSynthesizer.defaultVoice, style: .serious, language: .chinese)
        #expect(styled.effectiveModel == QwenSpeechSynthesizer.styledModel)
        #expect(styled.effectiveVoice == "xiaoxingzhi_v3.1")
        // English keeps the picked voice: the persona voices speak Chinese.
        let english = SpeechSynthesisConfiguration(provider: .qwen, model: "m", voice: "loongmary",
            style: .serious, language: .english)
        #expect(english.effectiveVoice == "loongmary")
        #expect(english.effectiveModel == "m")
        // Singapore was never verified for the persona voices, so it keeps the picked one.
        let intl = SpeechSynthesisConfiguration(provider: .qwen, model: "m", voice: "v", qwenUseIntl: true,
            style: .serious, language: .chinese)
        #expect(intl.effectiveVoice == "v")
    }

    // MARK: Wire — the persona rides the presentation request

    @Test func presentationRequestOmitsStandardAndToleratesUnknownStyles() throws {
        let target = ContentPresentationTarget.completion(sessionID: "s", completionID: "c")
        let plain = try JSONEncoder().encode(ContentPresentationRequest(sourceID: "src", target: target))
        #expect(!String(decoding: plain, as: UTF8.self).contains("voiceStyle"))
        let styled = ContentPresentationRequest(sourceID: "src", target: target, voiceStyle: .sultry)
        #expect(try JSONDecoder().decode(ContentPresentationRequest.self, from: JSONEncoder().encode(styled)) == styled)

        var object = try #require(try JSONSerialization.jsonObject(with: plain) as? [String: Any])
        object["voiceStyle"] = "fromTheFuture"
        let decoded = try JSONDecoder().decode(ContentPresentationRequest.self,
                                               from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.voiceStyle == .standard)
    }
}
