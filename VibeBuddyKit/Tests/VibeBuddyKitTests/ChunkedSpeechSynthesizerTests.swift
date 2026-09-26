import Foundation
import Testing
@testable import VibeBuddyKit

/// A 900-character spoken summary has to reach the vendors as pieces each of
/// them answers inside its timeout, and come back as one playable stream.
@Suite("Chunked read-aloud")
struct ChunkedSpeechSynthesizerTests {
    private actor Recorder: SpeechSynthesizer {
        var texts: [String] = []
        func synthesize(_ text: String, apiKey: String) async throws -> Data {
            texts.append(text)
            // Each piece carries its own ID3 tag, as both vendors' MP3s do.
            return Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 2, 0xAA, 0xBB]) + Data(text.utf8)
        }
    }

    @Test func shortTextIsOneUntouchedRequest() async throws {
        let recorder = Recorder()
        let audio = try await ChunkedSpeechSynthesizer(base: recorder).synthesize("任务完成。", apiKey: "k")
        #expect(await recorder.texts == ["任务完成。"])
        #expect(audio.prefix(3) == Data("ID3".utf8))
    }

    @Test func longTextSplitsAtSentencesAndJoinsInOrder() async throws {
        let sentence = "人家把第三步做完啦～下一步就是整理测试报告哦，然后等你来确认一下嘛。"
        let text = String(repeating: sentence, count: 25)
        let pieces = ChunkedSpeechSynthesizer.pieces(text)
        #expect(pieces.allSatisfy { $0.count <= ChunkedSpeechSynthesizer.pieceLimit })
        #expect(pieces.allSatisfy { $0.hasSuffix("。") })
        #expect(pieces.joined() == text)

        let recorder = Recorder()
        let audio = try await ChunkedSpeechSynthesizer(base: recorder).synthesize(text, apiKey: "k")
        #expect(Set(await recorder.texts) == Set(pieces))
        // Only the first piece keeps its tag; the text shows the order held.
        #expect(audio.prefix(3) == Data("ID3".utf8))
        let expected = pieces.enumerated().reduce(into: Data()) { data, entry in
            data += (entry.offset == 0 ? Data([0x49, 0x44, 0x33, 4, 0, 0, 0, 0, 0, 2, 0xAA, 0xBB]) : Data())
                + Data(entry.element.utf8)
        }
        #expect(audio == expected)
    }

    @Test func englishSplitsAtPeriodsNotMidWord() {
        let sentence = "The task is complete and every check passed on the build machine. "
        let text = String(repeating: sentence, count: 12) + "Version 1.3 ships next."
        let pieces = ChunkedSpeechSynthesizer.pieces(text)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.count <= ChunkedSpeechSynthesizer.pieceLimit && $0.hasSuffix(".") })
        #expect(pieces.last?.hasSuffix("Version 1.3 ships next.") == true)
    }

    @Test func aSentenceLongerThanAPieceIsCutAtClausesThenHard() {
        let clause = String(repeating: "字", count: 120) + "，"
        let pieces = ChunkedSpeechSynthesizer.pieces(clause + clause + String(repeating: "长", count: 400) + "。")
        #expect(pieces.allSatisfy { $0.count <= ChunkedSpeechSynthesizer.pieceLimit })
        #expect(pieces.first == clause)
    }

    @Test func blankAndRunawayInputAreRefused() async {
        let chunked = ChunkedSpeechSynthesizer(base: Recorder())
        await #expect(throws: SpeechSynthesisFailure.configuration) { try await chunked.synthesize("  \n", apiKey: "k") }
        let runaway = String(repeating: "长。", count: ChunkedSpeechSynthesizer.totalLimit)
        await #expect(throws: SpeechSynthesisFailure.configuration) { try await chunked.synthesize(runaway, apiKey: "k") }
    }
}
