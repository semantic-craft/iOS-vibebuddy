import Foundation
import Testing
@testable import VibeBuddyKit

struct MiniMaxSpeechTests {
    @Test func envelopeErrorsAndMalformedHexNeverBecomeAudio() throws {
        #expect(try MiniMaxSpeechSynthesizer.audio(from: Data(#"{"base_resp":{"status_code":0},"data":{"status":2,"audio":"4944aBff"}}"#.utf8)) == Data([73, 68, 171, 255]))
        for code in [1002, 1039] {
            #expect(throws: SpeechSynthesisFailure.rateLimited) {
                try MiniMaxSpeechSynthesizer.audio(from: Data("{\"base_resp\":{\"status_code\":\(code),\"status_msg\":\"secret\"}}".utf8))
            }
        }
        #expect(throws: SpeechSynthesisFailure.transport) {
            try MiniMaxSpeechSynthesizer.audio(from: Data(#"{"base_resp":{"status_code":0},"data":{"status":1,"audio":"494433"}}"#.utf8))
        }
        for code in [1008, 2056] {
            #expect(throws: SpeechSynthesisFailure.quotaExceeded) {
                try MiniMaxSpeechSynthesizer.audio(from: Data("{\"base_resp\":{\"status_code\":\(code)}}".utf8))
            }
        }
        #expect(throws: SpeechSynthesisFailure.configuration) {
            try MiniMaxSpeechSynthesizer.audio(from: Data(#"{"base_resp":{"status_code":1042}}"#.utf8))
        }
        for hex in ["abc", "0x12", "zz"] {
            #expect(throws: SpeechSynthesisFailure.transport) {
                try MiniMaxSpeechSynthesizer.audio(from: Data("{\"base_resp\":{\"status_code\":0},\"data\":{\"status\":2,\"audio\":\"\(hex)\"}}".utf8))
            }
        }
    }

    @Test func miniMaxCanFollowSummariesWithoutEnteringRealtime() throws {
        let name = "minimax-routing-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("minimax", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.minimax))
        defaults.set("minimax", forKey: VoiceSettings.readAloudProviderKey)
        defaults.set("deepseek", forKey: VoiceSettings.summaryProviderKey)
        #expect(VoiceSettings.readAloudStatus(defaults: defaults) == .ready(.minimax))
        #expect(!VoiceProvider.voiceProviders.contains(.minimax))
        #expect(VoiceProvider.readAloudProviders.contains(.minimax))
        #expect(VoiceCatalog.voices(.conversation, .minimax).isEmpty)
        #expect(VoiceSettings.readAloudVoice(.minimax, language: .english, defaults: defaults) == "English_Trustworthy_Man")
    }
}
