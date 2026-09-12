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
                // vendor is being asked, told, or led in.
                #expect(persona?.request.contains(persona?.clause ?? "#") == true)
                #expect(persona?.directive.contains(persona?.clause ?? "#") == true)
                #expect(persona?.leadIn.contains(persona?.clause ?? "#") == true)
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

    /// The instruction must be written in the language being read, or the
    /// vendor hears a language switch instead of a note about delivery.
    @Test func instructionLanguageFollowsTheSummary() throws {
        let chinese = try #require(VoiceStyle.girlNextDoor.persona(.chinese))
        let english = try #require(VoiceStyle.girlNextDoor.persona(.english))
        #expect(chinese.clause.contains("邻家小妹"))
        #expect(chinese.request.hasSuffix("？"))
        #expect(english.clause.allSatisfy { $0.isASCII || $0 == "—" })
        #expect(english.leadIn.hasSuffix(":"))
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

    // MARK: Gemini — no instruction field, so the prompt leads in

    @Test func geminiLeadsInBeforeTheSummary() throws {
        let persona = try #require(VoiceStyle.fieryGirl.persona(.english))
        let prompt = GeminiSpeechSynthesizer(persona: persona).prompt("The task is complete.")
        #expect(prompt.hasPrefix(persona.leadIn))
        #expect(prompt.hasSuffix("The task is complete."))
        // The summary must survive intact — a persona may not rewrite it.
        #expect(GeminiSpeechSynthesizer().prompt("The task is complete.") == "The task is complete.")
    }

    // MARK: Which vendors offer it

    @Test func onlyVendorsWithAnInstructionChannelOfferStyle() {
        #expect(SpeechSynthesis.support(.doubao).supportsStyle)
        #expect(SpeechSynthesis.support(.qwen).supportsStyle)
        #expect(SpeechSynthesis.support(.gemini).supportsStyle)
        #expect(!SpeechSynthesis.support(.openai).supportsStyle)
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
        #expect(VoiceSettings.readAloudStyle(.gemini, defaults: defaults) == .standard)
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
