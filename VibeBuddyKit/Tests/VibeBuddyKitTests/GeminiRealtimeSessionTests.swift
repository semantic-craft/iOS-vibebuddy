import Foundation
import Testing
@testable import VibeBuddyKit

@Suite struct GeminiRealtimeSessionTests {
    @Test func cancellationAndSecondTurnKeepIdentityAndSession() async throws {
        let wire = GeminiWireFixture()
        let session = GeminiRealtimeSession(model: "gemini-3.8-live", transport: wire.transport)
        let events = await session.start(instructions: "test", voice: "Kore", tools: [VoiceTools.status])
        let deadline = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { await session.close() } }
        defer { deadline.cancel() }
        var iterator = events.makeAsyncIterator()
        wire.push(#"{"setupComplete":{}}"#)
        guard case .connected = await iterator.next() else { Issue.record("not connected"); return }
        wire.push(#"{"toolCall":{"functionCalls":[{"id":"a","name":"get_session_status","args":{}}]}}"#)
        guard case .toolCall(_, _, "a") = await iterator.next() else { Issue.record("missing tool"); return }
        wire.push(#"{"toolCallCancellation":{"ids":["a"]}}"#)
        guard case .toolCallsCancelled(["a"]) = await iterator.next() else { Issue.record("missing cancel"); return }
        await session.sendToolResult(callID: "a", name: "get_session_status", result: "cancelled")
        wire.push(#"{"serverContent":{"turnComplete":true}}"#)
        guard case .responseDone = await iterator.next() else { Issue.record("missing turn"); return }
        wire.push(#"{"toolCall":{"functionCalls":[{"id":"b","name":"get_session_status","args":{}}]}}"#)
        guard case .toolCall(_, _, "b") = await iterator.next() else { Issue.record("second turn closed"); return }
        await session.sendToolResult(callID: "b", name: "get_session_status", result: #"{"status":"waiting"}"#)
        let messages = await wire.sent.values
        #expect(messages.count == 2)
        #expect(messages.last?.contains("waiting") == true)
        #expect(messages.last?.contains("\"id\":\"b\"") == true)
        await session.close()
    }
    @Test func interruptionDiscardsOldOutputUntilTurnBoundaryAndGoAwayIsOnlyNotice() async {
        let wire = GeminiWireFixture()
        var transport = wire.transport
        transport.cleanClose = { true }
        let session = GeminiRealtimeSession(model: "gemini-3.8-live", transport: transport)
        let events = await session.start(instructions: "test", voice: "Kore", tools: [])
        let deadline = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled { await session.close() } }
        defer { deadline.cancel() }
        wire.push(#"{"setupComplete":{}}"#)
        wire.push(#"{"serverContent":{"interrupted":true}}"#)
        wire.push(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAE="}}]}}}"#)
        wire.push(#"{"toolCall":{"functionCalls":[{"id":"stale","name":"get_session_status","args":{}}]}}"#)
        wire.push(#"{"serverContent":{"turnComplete":true}}"#)
        wire.push(#"{"goAway":{"timeLeft":"30s"}}"#)
        wire.push(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AAE="}}]}}}"#)
        wire.continuation.finish()
        var audioCount = 0, limits = 0, turns = 0
        for await event in events {
            switch event {
            case .audioDelta: audioCount += 1
            case .providerLimitReached: limits += 1
            case .responseDone: turns += 1
            case .toolCall: Issue.record("interrupted tool escaped")
            case .failed: Issue.record("clean preannounced close became failure")
            default: break
            }
        }
        #expect(audioCount == 1); #expect(turns == 1); #expect(limits == 1)
    }

}

private final class GeminiWireFixture: @unchecked Sendable {
    actor Sent { var values: [String] = []; func add(_ text: String) { values.append(text) } }
    let sent = Sent()
    let stream: AsyncStream<String>
    let continuation: AsyncStream<String>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func push(_ text: String) { continuation.yield(text) }
    var transport: GeminiLiveTransport {
        GeminiLiveTransport(messages: stream, send: { [sent] in await sent.add($0) }, close: { [continuation] in continuation.finish() })
    }
}

/// Explicit opt-in only. Input is raw mono PCM16 LE at 16 kHz. This is a native
/// provider acceptance check, not device microphone/speaker acceptance.
@Suite struct GeminiLiveAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_LIVE_ACCEPTANCE"] == "1"))
    func twoAudioTurnsWithCorrelatedStatusResults() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["GEMINI_API_KEY"])
        let path = try #require(env["GEMINI_LIVE_PCM_PATH"])
        let pcm = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(!pcm.isEmpty && pcm.count.isMultiple(of: 2))
        let result = try env["GEMINI_LIVE_TOOL_RESULT_PATH"].map { try String(contentsOfFile: $0, encoding: .utf8) }
            ?? #"{"status":"waiting_for_device_verification","action":"none"}"#
        let session = GeminiRealtimeSession(apiKey: key)
        let events = await session.start(instructions: "用中文简短回答。用户每次询问任务状态必须调用 get_session_status，根据返回的真实结果回答，不要猜测。", voice: "Kore", tools: [VoiceTools.status])
        let deadline = Task { try? await Task.sleep(for: .seconds(90)); if !Task.isCancelled { await session.close() } }
        defer { deadline.cancel() }
        var turns = 0, audioBytes = 0, inputCaptions = 0, outputCaptions = 0
        var callIDs = Set<String>()
        var feeder: Task<Void, Never>?
        func feed() -> Task<Void, Never> {
            Task {
                // Two seconds of trailing silence lets server VAD settle.
                let input = pcm + Data(repeating: 0, count: 64_000)
                for offset in stride(from: 0, to: input.count, by: 3200) {
                    guard !Task.isCancelled else { return }
                    await session.appendAudio(input.subdata(in: offset..<min(offset + 3200, input.count)))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        for await event in events {
            switch event {
            case .connected: feeder = feed()
            case .toolCall(let name, _, let id):
                #expect(name == "get_session_status")
                #expect(callIDs.insert(id).inserted)
                await session.sendToolResult(callID: id, name: name, result: result)
            case .audioDelta(let data, _): audioBytes += data.count
            case .userTranscript: inputCaptions += 1
            case .assistantTranscript: outputCaptions += 1
            case .responseDone:
                turns += 1
                if turns == 1 { feeder?.cancel(); feeder = feed() }
                else { await session.close() }
            case .failed(let message): Issue.record("\(message)"); await session.close()
            default: break
            }
        }
        feeder?.cancel()
        #expect(turns >= 2); #expect(callIDs.count >= 2)
        #expect(audioBytes > 0); #expect(inputCaptions > 0); #expect(outputCaptions > 0)
        print("Gemini native Live acceptance: turns=\(turns) calls=\(callIDs.count) audioBytes=\(audioBytes) inputCaptions=\(inputCaptions) outputCaptions=\(outputCaptions)")
    }
}
