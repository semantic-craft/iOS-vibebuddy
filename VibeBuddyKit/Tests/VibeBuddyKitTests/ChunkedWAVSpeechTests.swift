import AVFoundation
import Foundation
import Testing
@testable import VibeBuddyKit

struct ChunkedWAVSpeechTests {
    private struct WAVSpeech: SpeechSynthesizer {
        func synthesize(_ text: String, apiKey: String) async throws -> Data {
            // The two independently valid WAVs have distinct sample values.
            let value: UInt8 = text.first == "甲" ? 1 : 2
            return SpeechSynthesisHTTP.wav(pcm16: Data(repeating: value, count: 48_000), sampleRate: 24_000)
        }
    }

    @Test func longGeminiReadingDecodesAllWAVPiecesInOrder() async throws {
        let text = String(repeating: "甲", count: 180) + String(repeating: "乙", count: 180)
        let audio = try await ChunkedSpeechSynthesizer(base: WAVSpeech(), joinsWAV: true).synthesize(text, apiKey: "test")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gemini-chunks-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try audio.write(to: file)
        let decoded = try AVAudioFile(forReading: file, commonFormat: .pcmFormatInt16, interleaved: false)
        #expect(decoded.length == 48_000) // Two seconds, not just the first RIFF's second.
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 48_000))
        var samples: [Int16] = []
        // A native read can return less than the file length; drain to EOF.
        while decoded.framePosition < decoded.length {
            try decoded.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let channel = try #require(buffer.int16ChannelData?[0])
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        #expect(samples.count == 48_000)
        #expect(samples.first == 257)
        if samples.count == 48_000 { #expect(samples[24_000] == 514) }
    }
}
