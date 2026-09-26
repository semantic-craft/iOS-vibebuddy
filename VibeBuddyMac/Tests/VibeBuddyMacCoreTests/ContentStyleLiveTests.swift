import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_CONTENT_STYLE_LIVE"] == "1"))
struct ContentStyleLiveTests {
    @Test func realConversationAcrossStylesAndPurposes() async throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["VIBEBUDDY_CONTENT_STYLE_SOURCE"])
        let secret = try #require(env["DASHSCOPE_API_KEY"])
        let output = try #require(env["VIBEBUDDY_CONTENT_STYLE_OUTPUT"])
        let history = try SessionHistoryParser.read(url: URL(fileURLWithPath: path), agent: .codex, updatedAt: Date())
        let final = try #require(history.messages.last(where: { $0.role == .assistant })?.text)
        let http = CompletionSummaryHTTP(session: CompletionSummaryHTTP.session(timeout: 45))
        var rows: [[String: String]] = []
        for style in ContentStyle.allCases {
            var config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: "qwen3.8-flash", language: .chinese)
            config.contentStyle = .init(style: style, customPrompt: "用两句自然中文汇报。第一句讲实际改善，第二句讲尚未确认的事项。")
            for purpose in [SummaryPurpose.speech, .notice] {
                let now = Date()
                let input = CompletionSummaryInput(sourceID: "content-style-live", sessionID: history.id,
                    completionID: UUID().uuidString, title: "VibeBuddy", finalText: final,
                    completedAt: now, observedAt: now)
                let request = try CompletionSummaryHTTP.request(input: input, configuration: config, key: secret, timeout: 45, purpose: purpose)
                let (data, _) = try await http.session.data(for: request)
                let response = CompletionSummaryHTTP.decode(data, provider: .qwen, purpose: purpose)
                if response.text == nil {
                    let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let rejected = ((raw?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
                    rows.append(["style": style.rawValue, "purpose": purpose.rawValue, "rejectedText": rejected, "failure": response.failure?.rawValue ?? "unknown"])
                    try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
                }
                let text = try #require(response.text, "\(style.rawValue)/\(purpose.rawValue): \(response.failure?.rawValue ?? "unknown")")
                #expect(!text.contains("```"))
                #expect(!text.contains("git reset") && !text.contains("git push"))
                rows.append(["style": style.rawValue, "purpose": purpose.rawValue, "text": text])
                try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        let decisionInput = CompletionSummaryInput(sourceID: "content-style-fixture", sessionID: "explicit-decision", completionID: UUID().uuidString,
            title: "客户反馈工具", finalText: "用户明确待决问题：本周先上线搜索，还是等两周把自动分类一起上线？方案A本周交付搜索，员工先不用逐条翻找反馈，但自动分类还要手动做。方案B需要再等两周，届时搜索和自动分类一起提供，等待期间员工继续逐条整理。原记录建议选A，因为用户已明确本周能查找反馈最重要。尚未获用户决定，两个方案都未上线。", completedAt: Date(), observedAt: Date())
        let decisionConfig = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: "qwen3.8-flash", language: .chinese, contentStyle: .init(style: .decision))
        let decisionResponse = await http.generate(input: decisionInput, configuration: decisionConfig, key: secret, timeout: 45, purpose: .speech)
        let decisionText = try #require(decisionResponse.text)
        rows.append(["style": "decision", "purpose": "explicit-choice-fixture", "text": decisionText])
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        print("Verified \(rows.count) real Qwen outputs; saved to \(output)")
    }

    /// Each read-aloud persona rewords the same record without losing the
    /// failure or the pending action. Run with VIBEBUDDY_CONTENT_STYLE_OUTPUT
    /// to keep the texts for a listening pass.
    @Test func voicePersonasRewordWithoutLosingFacts() async throws {
        let env = ProcessInfo.processInfo.environment
        let secret = try #require(env["DASHSCOPE_API_KEY"])
        let http = CompletionSummaryHTTP(session: CompletionSummaryHTTP.session(timeout: 45))
        let record = "已把登录页改成手机号验证码登录，老用户也能直接用原手机号登录。安卓端的验证码短信在部分机型上收不到，原因是短信模板还没通过运营商审核，已提交审核，预计明天出结果。需要用户决定：审核通过前，是先只给 iOS 用户开放新登录，还是等安卓一起上线？"
        var rows: [[String: String]] = []
        for style in VoiceStyle.allCases {
            var config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: "qwen3.8-flash", language: .chinese)
            config.speechStyle = style
            let now = Date()
            let input = CompletionSummaryInput(sourceID: "voice-style-live", sessionID: "voice-style", completionID: UUID().uuidString,
                title: "登录改版", finalText: record, completedAt: now, observedAt: now)
            let response = await http.generate(input: input, configuration: config, key: secret, timeout: 45, purpose: .speech)
            let text = try #require(response.text, "\(style.rawValue): \(response.failure?.rawValue ?? "unknown")")
            #expect(text.contains("安卓"), "\(style.rawValue) dropped the failure")
            #expect(text.contains("iOS"), "\(style.rawValue) dropped the pending decision")
            // A listener who only catches the end must still hear the decision.
            var last = ""
            text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { sentence, _, _, _ in
                if let sentence, !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { last = sentence }
            }
            #expect(last.contains("iOS") || last.contains("安卓"), "\(style.rawValue) ended on: \(last)")
            rows.append(["style": style.rawValue, "text": text])
        }
        if let output = env["VIBEBUDDY_CONTENT_STYLE_OUTPUT"] {
            try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
    }
}
