import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("QwenRealtimeSession — endpoint + session.update for Qwen-Audio 3.0 Realtime")
struct QwenRealtimeSessionTests {

    @Test("no workspace ID → shared dashscope domains")
    func sharedDomains() {
        #expect(QwenRealtimeSession.endpoint(model: "qwen-audio-3.0-realtime-plus", workspaceID: nil, useIntl: false).absoluteString
                == "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus")
        #expect(QwenRealtimeSession.endpoint(model: "qwen-audio-3.0-realtime-plus", workspaceID: nil, useIntl: true).absoluteString
                == "wss://dashscope-intl.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus")
    }

    @Test("workspace ID → workspace-specific maas endpoint per region")
    func workspaceDomains() {
        #expect(QwenRealtimeSession.endpoint(model: "qwen-audio-3.0-realtime-plus", workspaceID: "llm-abc", useIntl: false).absoluteString
                == "wss://llm-abc.cn-beijing.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus")
        #expect(QwenRealtimeSession.endpoint(model: "qwen-audio-3.0-realtime-plus", workspaceID: "llm-abc", useIntl: true).absoluteString
                == "wss://llm-abc.ap-southeast-1.maas.aliyuncs.com/api-ws/v1/realtime?model=qwen-audio-3.0-realtime-plus")
    }

    @Test("session.update uses smart_turn, no audio-format keys, and the flat tool schema")
    func sessionConfig() {
        let s = QwenRealtimeSession.sessionConfig(instructions: "hi", voice: "longanqian", tools: VoiceTools.all)
        #expect((s["turn_detection"] as? [String: Any])?["type"] as? String == "smart_turn")
        #expect(s["input_audio_transcription"] == nil)
        #expect(s["input_audio_format"] == nil)
        #expect(s["voice"] as? String == "longanqian")
        #expect((s["tools"] as? [[String: Any]])?.count == VoiceTools.all.count)
        #expect(s["tool_choice"] as? String == "auto")
        #expect(QwenRealtimeSession.sessionConfig(instructions: "hi", voice: "longanqian", tools: [])["tools"] == nil)
    }
}
