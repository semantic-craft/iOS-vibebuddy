import AVFoundation
import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Explicit opt-in acceptance: the caller supplies a Token Plan key and a real
/// agent result file. Never reads another app's credentials or prints the key.
struct MiniMaxLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMAX_E2E"] == "1"))
    func summaryAndStyledSpeech() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["MINIMAX_API_KEY"])
        let source = try #require(env["MINIMAX_SOURCE"])
        let output = URL(fileURLWithPath: try #require(env["MINIMAX_OUTPUT"]), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let text = try String(contentsOfFile: source, encoding: .utf8)
        let now = Date()
        let input = CompletionSummaryInput(sourceID: "minimax-acceptance", sessionID: "minimax-acceptance",
            completionID: UUID().uuidString, turnID: UUID().uuidString, title: "MiniMax acceptance",
            finalText: text, completedAt: now, observedAt: now)
        let session = CompletionSummaryHTTP.session(timeout: 30)
        defer { session.invalidateAndCancel() }
        var evidence: [[String: Any]] = []
        // Exercise the actual short-notification contract too, without the
        // benchmark's former token-budget override or a longer deadline.
        let noticeConfig = CompletionSummaryConfiguration(enabled: true, provider: .minimax,
            modelID: CompletionSummaryConfiguration.recommendedModel(.minimax), language: .chinese)
        let noticeStart = Date()
        let notice = await CompletionSummaryHTTP(session: session).generate(input: input,
            configuration: noticeConfig, key: key, timeout: 12, purpose: .notice)
        #expect(notice.failure == nil)
        let noticeText = try #require(notice.text)
        evidence.append(["purpose": "notice", "summary": noticeText,
                         "summarySeconds": Date().timeIntervalSince(noticeStart)])
        for style in VoiceStyle.allCases {
            var config = CompletionSummaryConfiguration(enabled: true, provider: .minimax,
                modelID: CompletionSummaryConfiguration.recommendedModel(.minimax), language: .chinese)
            config.speechStyle = style
            let start = Date()
            let result = await CompletionSummaryHTTP(session: session).generate(input: input,
                configuration: config, key: key, timeout: 30, purpose: .speech)
            let summarySeconds = Date().timeIntervalSince(start)
            #expect(result.failure == nil)
            let summary = try #require(result.text)
            let speech = SpeechSynthesisConfiguration(provider: .minimax,
                model: MiniMaxSpeechSynthesizer.defaultModel, voice: MiniMaxSpeechSynthesizer.defaultVoice,
                style: style, language: .chinese)
            let synthesizer = try #require(SpeechSynthesis.synthesizer(speech))
            let speechStart = Date()
            let audio = try await synthesizer.synthesize(summary, apiKey: key)
            let audioSeconds = Date().timeIntervalSince(speechStart)
            let player = try AVAudioPlayer(data: audio)
            #expect(player.duration > 0)
            try audio.write(to: output.appendingPathComponent("\(style.rawValue).mp3"))
            evidence.append(["style": style.rawValue, "model": config.modelID,
                "voice": speech.effectiveVoice, "summarySeconds": summarySeconds,
                "synthesisSeconds": audioSeconds, "duration": player.duration, "summary": summary])
        }
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("timing.json"))
    }
}
