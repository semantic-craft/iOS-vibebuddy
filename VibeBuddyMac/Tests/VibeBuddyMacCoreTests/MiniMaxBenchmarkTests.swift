import AVFoundation
import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Opt-in, bounded comparison. Uses production summary prompts, output checks,
/// and the TTS adapter; writes only answers, timings and sanitized error codes.
struct MiniMaxBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MINIMAX_BENCHMARK"] == "1"))
    func compareModels() async throws {
        let key = try #require(ProcessInfo.processInfo.environment["MINIMAX_API_KEY"])
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MINIMAX_OUTPUT"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let models = ["MiniMax-M3", "MiniMax-M3.1-Flash-Preview", "MiniMax-M2.7-highspeed"]
        let samples = [
            "已修复重复通知。本地构建和回归检查通过，尚未在手机上验收，没有提交或发布。",
            "已完成三步计划的前两步：接入新供应商并增加设置。第三步真实请求测试因缺少密钥尚未开始。目前没有测速结果，不能判断哪个模型最快。"
        ]
        let session = CompletionSummaryHTTP.session(timeout: 30)
        defer { session.invalidateAndCancel() }
        var records: [[String: Any]] = []
        var unavailable = Set<String>()
        func save() throws {
            try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("results.json"), options: .atomic)
        }
        for round in 0..<2 {
            for (sample, text) in samples.enumerated() {
                // Rotate order to avoid always granting one model the warmest connection.
                for offset in models.indices {
                    let model = models[(offset + sample + round) % models.count]
                    if unavailable.contains(model) { continue }
                    let now = Date()
                    let input = CompletionSummaryInput(sourceID: "benchmark", sessionID: "benchmark",
                        completionID: UUID().uuidString, turnID: UUID().uuidString, title: "模型接入",
                        finalText: text, completedAt: now, observedAt: now)
                    let config = CompletionSummaryConfiguration(enabled: true, provider: .minimax,
                        modelID: model, language: .chinese)
                    let request = try CompletionSummaryHTTP.request(input: input, configuration: config,
                        key: key, timeout: 30, purpose: .speech)
                    var record: [String: Any] = ["kind": "summary", "model": model, "sample": sample, "round": round]
                    let start = Date()
                    do {
                        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
                        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                        record["httpStatus"] = status
                        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let code = (root?["base_resp"] as? [String: Any])?["status_code"] as? Int
                        record["providerCode"] = code
                        if (200..<300).contains(status) {
                            let result = CompletionSummaryHTTP.decode(data, provider: .minimax, purpose: .speech)
                            record["failure"] = result.failure?.rawValue
                            record["text"] = result.text
                            record["outputTokens"] = result.usage?.outputTokens
                            let choices = root?["choices"] as? [[String: Any]]
                            let message = choices?.first?["message"] as? [String: Any]
                            record["reasoningCharacters"] = (message?["reasoning_content"] as? String)?.count ?? 0
                        } else { record["failure"] = "httpError" }
                        if [400, 401, 403, 404].contains(status) || [1004, 1008, 2049].contains(code ?? 0) {
                            unavailable.insert(model)
                        }
                    } catch { record["failure"] = "networkOrTimeout" }
                    record["seconds"] = Date().timeIntervalSince(start)
                    records.append(record); try save()
                    print("MiniMax benchmark summary model=\(model) seconds=\(record["seconds"]!) failure=\(record["failure"] ?? "none")")
                }
            }
        }
        let speechModels = ["speech-2.8-turbo", "speech-2.8-hd", "speech-2.6-turbo"]
        let styles: [VoiceStyle] = [.serious, .coquettish, .sultry]
        for round in 0..<2 {
            for (index, style) in styles.enumerated() {
                for offset in speechModels.indices {
                    let model = speechModels[(offset + index + round) % speechModels.count]
                    if unavailable.contains(model) { continue }
                    let voice = try #require(style.voice(for: .minimax, language: .chinese)?.voice)
                    let text = try #require(style.previewLine(.chinese))
                    var record: [String: Any] = ["kind": "speech", "model": model, "style": style.rawValue,
                        "voice": voice, "round": round, "text": text]
                    let start = Date()
                    do {
                        let audio = try await MiniMaxSpeechSynthesizer(model: model, voice: voice, style: style)
                            .synthesize(text, apiKey: key)
                        record["seconds"] = Date().timeIntervalSince(start)
                        let player = try AVAudioPlayer(data: audio)
                        record["duration"] = player.duration
                        record["bytes"] = audio.count
                        if round == 0 { try audio.write(to: output.appendingPathComponent("\(model)-\(style.rawValue).mp3")) }
                    } catch let failure as SpeechSynthesisFailure {
                        record["failure"] = failure.rawValue
                        if failure == .rejected { unavailable.insert(model) }
                    } catch { record["failure"] = "audioDecoding" }
                    if record["seconds"] == nil { record["seconds"] = Date().timeIntervalSince(start) }
                    records.append(record); try save()
                    print("MiniMax benchmark speech model=\(model) style=\(style.rawValue) seconds=\(record["seconds"]!) failure=\(record["failure"] ?? "none")")
                }
            }
        }
        #expect(records.contains { $0["kind"] as? String == "summary" && $0["text"] != nil })
        #expect(records.contains { $0["kind"] as? String == "speech" && $0["duration"] != nil })
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
