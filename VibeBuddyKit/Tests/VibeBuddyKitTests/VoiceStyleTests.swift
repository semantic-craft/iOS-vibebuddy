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

    @Test func standardSendsNothingAndEveryTierSpeaksBothLanguages() {
        for language in VoiceLanguage.allCases {
            #expect(VoiceStyle.standard.persona(language) == nil)
            for style in VoiceStyle.allCases where style != .standard {
                let persona = style.persona(language)
                #expect(persona != nil)
                // Each form has to be a whole sentence, not a bare clause: the
                // vendor is being asked or told.
                #expect(persona?.request.contains(persona?.clause ?? "#") == true)
                #expect(persona?.directive.contains(persona?.clause ?? "#") == true)
            }
        }
    }

    @Test func unparseableStoredStyleReadsPlainly() {
        for stored in [nil, "", "   ", "unknown", "GirlNextDoor"] as [String?] {
            #expect(VoiceStyle(stored: stored) == .standard)
        }
        #expect(VoiceStyle(stored: " girlNextDoor ") == .girlNextDoor)
        #expect(VoiceStyle(stored: "fieryGirl") == .fieryGirl)
    }

    // MARK: Doubao — additions.context_texts, and `additions` is a jsonstring

    @Test func doubaoCarriesThePersonaInContextTextsAsAJSONString() throws {
        let persona = try #require(VoiceStyle.fieryGirl.persona(.chinese))
        let body = DoubaoSpeechSynthesizer(persona: persona).requestBody("摘要")
        let params = try #require(body["req_params"] as? [String: Any])
        // A jsonstring per the V3 docs — an object here is a parameter error.
        let additions = try #require(params["additions"] as? String)
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(additions.utf8)) as? [String: Any])
        #expect(decoded["context_texts"] as? [String] == [persona.request])
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
        let persona = try #require(VoiceStyle.girlNextDoor.persona(.chinese))
        let styled = QwenSpeechSynthesizer(workspaceID: nil, useIntl: false, persona: persona).parameters()
        #expect(styled["instruction"] as? String == persona.directive)
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

        defaults.set(VoiceStyle.fieryGirl.rawValue, forKey: VoiceSettings.readAloudStyleKey(.doubao))
        defaults.set(VoiceStyle.fieryGirl.rawValue, forKey: VoiceSettings.readAloudStyleKey(.openai))
        #expect(VoiceSettings.readAloudStyle(.doubao, defaults: defaults) == .fieryGirl)
        #expect(VoiceSettings.readAloudStyle(.openai, defaults: defaults) == .standard)
    }

    @Test func configurationCarriesStyleAndTheSpokenLanguage() throws {
        let name = "voice-style-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(VoiceStyle.girlNextDoor.rawValue, forKey: VoiceSettings.readAloudStyleKey(.doubao))
        defaults.set(VoiceLanguage.chinese.rawValue, forKey: VoiceSettings.conversationLanguageKey)

        let configuration = VoiceSettings.readAloudConfiguration(.doubao, defaults: defaults)
        #expect(configuration.style == .girlNextDoor)
        #expect(configuration.language == .chinese)
        #expect(configuration.persona?.clause == VoiceStyle.girlNextDoor.persona(.chinese)?.clause)
    }
}
