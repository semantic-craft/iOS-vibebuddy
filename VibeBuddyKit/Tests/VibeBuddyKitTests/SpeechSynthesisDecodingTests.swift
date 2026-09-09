import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Speech synthesis response decoding")
struct SpeechSynthesisDecodingTests {
    private func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

    // MARK: Gemini

    @Test func geminiWrapsHeaderlessPCMSoAPlayerWillOpenIt() throws {
        let pcm: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let body = """
        {"candidates":[{"content":{"role":"model","parts":[
          {"inlineData":{"mimeType":"audio/L16;codec=pcm;rate=16000","data":"\(base64(pcm))"}}]}}]}
        """
        let audio = try GeminiSpeechSynthesizer.audio(from: Data(body.utf8))
        #expect(audio.prefix(4).elementsEqual(Array("RIFF".utf8)))
        #expect(audio.count == 44 + pcm.count)
        // The rate the response declared, little-endian at the WAV header's offset 24.
        let rate = audio[24...27].reversed().reduce(0) { $0 << 8 | Int($1) }
        #expect(rate == 16_000)
        #expect(Array(audio.suffix(pcm.count)) == pcm)
    }

    @Test func geminiFallsBackToTheDocumentedRateAndJoinsChunks() throws {
        let body = """
        {"candidates":[{"content":{"parts":[
          {"inlineData":{"mimeType":"audio/L16","data":"\(base64([1, 2]))"}},
          {"inlineData":{"mimeType":"audio/L16","data":"\(base64([3, 4]))"}}]}}]}
        """
        let audio = try GeminiSpeechSynthesizer.audio(from: Data(body.utf8))
        let rate = audio[24...27].reversed().reduce(0) { $0 << 8 | Int($1) }
        #expect(rate == GeminiSpeechSynthesizer.defaultSampleRate)
        #expect(Array(audio.suffix(4)) == [1, 2, 3, 4])
    }

    @Test func geminiGradesRefusalAndSilence() {
        #expect(throws: SpeechSynthesisFailure.rejected) {
            try GeminiSpeechSynthesizer.audio(from: Data(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#.utf8))
        }
        #expect(throws: SpeechSynthesisFailure.emptyAudio) {
            try GeminiSpeechSynthesizer.audio(from: Data(#"{"candidates":[{"content":{"parts":[]}}]}"#.utf8))
        }
        #expect(throws: SpeechSynthesisFailure.transport) {
            try GeminiSpeechSynthesizer.audio(from: Data("not json".utf8))
        }
    }

    // MARK: Doubao

    @Test func doubaoJoinsTheStreamedChunks() throws {
        let body = """
        {"code":0,"message":"ok","data":"\(base64([9, 9]))"}
        {"code":0,"message":"ok","data":"\(base64([8, 8]))"}
        {"code":0,"message":"ok","data":""}
        """
        let audio = try DoubaoSpeechSynthesizer.audio(from: Data(body.utf8))
        #expect(Array(audio) == [9, 9, 8, 8])
    }

    @Test func doubaoTreatsTheTerminalStatusFrameAsTheEndOfTheStream() throws {
        // The stream closes with code 20000000 "OK" after the audio; reading it
        // as an error threw away a complete recording.
        let body = """
        {"code":0,"message":"","data":"\(base64([1, 2]))"}
        {"code":0,"message":"","data":"\(base64([3, 4]))","sentence":{"words":[]}}
        {"code":20000000,"message":"OK","data":""}
        """
        #expect(Array(try DoubaoSpeechSynthesizer.audio(from: Data(body.utf8))) == [1, 2, 3, 4])
        #expect(DoubaoSpeechSynthesizer.failure(for: 20_000_000) == nil)
        #expect(DoubaoSpeechSynthesizer.failure(for: 20_000_002) == nil)
        #expect(DoubaoSpeechSynthesizer.failure(for: 0) == nil)
    }

    @Test func doubaoGradesItsOwnCodesWithoutRepeatingThem() {
        for (code, expected) in [(401, SpeechSynthesisFailure.rejected), (403, .rejected),
                                 (429, .rateLimited), (55_000_001, .transport)] {
            #expect(throws: expected) {
                try DoubaoSpeechSynthesizer.audio(from: Data("{\"code\":\(code),\"message\":\"key leaked here\"}".utf8))
            }
        }
        #expect(throws: SpeechSynthesisFailure.transport) {
            try DoubaoSpeechSynthesizer.audio(from: Data("<html>gateway</html>".utf8))
        }
        #expect(throws: SpeechSynthesisFailure.emptyAudio) {
            try DoubaoSpeechSynthesizer.audio(from: Data(#"{"code":0,"data":""}"#.utf8))
        }
    }

    // MARK: Shared

    @Test func everyFailureSaysSomethingActionableAndNothingBorrowed() {
        for failure in [SpeechSynthesisFailure.configuration, .rejected, .rateLimited,
                        .unreachable, .timedOut, .transport, .emptyAudio, .excessiveAudio] {
            #expect(!failure.message.isEmpty)
            #expect(failure.message.hasSuffix("."))
        }
        #expect(SpeechSynthesisFailure.rejected.message.contains("key"))
        #expect(SpeechSynthesisFailure.unreachable.message.contains("connection"))
    }

    @Test func aSummaryIsTwoSentences_notADocumentAndNotEmpty() throws {
        #expect(throws: SpeechSynthesisFailure.configuration) {
            _ = try SpeechSynthesisHTTP.checkedText("hello", apiKey: "")
        }
        #expect(throws: SpeechSynthesisFailure.configuration) {
            _ = try SpeechSynthesisHTTP.checkedText("   ", apiKey: "k")
        }
        #expect(throws: SpeechSynthesisFailure.configuration) {
            _ = try SpeechSynthesisHTTP.checkedText(String(repeating: "x", count: 181), apiKey: "k")
        }
        let trimmed = try SpeechSynthesisHTTP.checkedText("  spoken  ", apiKey: "k")
        #expect(trimmed == "spoken")
    }
}
