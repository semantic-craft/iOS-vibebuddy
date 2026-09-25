import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Speech synthesis response decoding")
struct SpeechSynthesisDecodingTests {
    private func base64(_ bytes: [UInt8]) -> String { Data(bytes).base64EncodedString() }

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
