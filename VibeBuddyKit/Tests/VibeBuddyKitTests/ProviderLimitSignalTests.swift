import Foundation
import Testing
@testable import VibeBuddyKit

/// D-1: each provider's explicit per-connection-limit signal maps to
/// `.providerLimitReached`; unrelated endings stay failures.
@Suite("Provider limit — per-provider end-reason mapping")
struct ProviderLimitSignalTests {

    private func isLimit(_ event: RealtimeVoiceEvent) -> Bool {
        if case .providerLimitReached = event { return true }
        return false
    }

    @Test("OpenAI Realtime: only error code session_expired is the limit")
    func openAIRealtime() {
        #expect(ProviderLimitSignal.isOpenAIRealtimeLimit(error: ["type": "error", "error": [
            "type": "invalid_request_error", "code": "session_expired",
            "message": "Your session hit the maximum duration of 60 minutes."]]))
        #expect(!ProviderLimitSignal.isOpenAIRealtimeLimit(error: ["type": "error", "error": [
            "type": "invalid_request_error", "code": "rate_limit_exceeded",
            "message": "Your session hit the maximum duration of 60 minutes."]]))
        #expect(!ProviderLimitSignal.isOpenAIRealtimeLimit(error: ["type": "error", "error": ["message": "session expired"]]))
    }

    @Test("GPT-Live: session.closed reason expired is the limit; other reasons are not",
          arguments: ["close_requested", "content", "remote_hangup", "connection_lost"])
    func openAILive(otherReason: String) {
        #expect(ProviderLimitSignal.isOpenAILiveLimit(closed: ["type": "session.closed", "reason": "expired"]))
        #expect(!ProviderLimitSignal.isOpenAILiveLimit(closed: ["type": "session.closed", "reason": otherReason]))
        #expect(!ProviderLimitSignal.isOpenAILiveLimit(closed: ["type": "session.closed"]))
    }

    @Test("Qwen: a server close frame at the 120-minute session limit is the limit")
    func qwenAtLimit() {
        let atLimit = QwenRealtimeSession.connectionEndEvent(status: 101, detail: "closed",
            serverCloseCode: .normalClosure, connectedFor: 120 * 60)
        #expect(isLimit(atLimit))
        let internalError = QwenRealtimeSession.connectionEndEvent(status: 101, detail: "closed",
            serverCloseCode: .internalServerError, connectedFor: 120 * 60 + 5)
        #expect(isLimit(internalError))
    }

    @Test("Qwen: an early close or a drop without a close frame stays a failure")
    func qwenNotLimit() {
        for (code, age) in [(URLSessionWebSocketTask.CloseCode.normalClosure, 30.0 * 60),
                            (.invalid, 120.0 * 60), (.abnormalClosure, 125.0 * 60)] {
            let event = QwenRealtimeSession.connectionEndEvent(status: 101, detail: "The network connection was lost.",
                serverCloseCode: code, connectedFor: age)
            #expect(!isLimit(event))
            if case .failed(let message) = event { #expect(message.contains("Qwen connection interrupted")) }
            else { Issue.record("expected a failure, got \(event)") }
        }
        let auth = QwenRealtimeSession.connectionEndEvent(status: 401, detail: "bad key",
            serverCloseCode: .invalid, connectedFor: 0)
        #expect(!isLimit(auth))
    }

    @Test("Gemini: the socket ending after goAway is the limit; without goAway it is a failure")
    func gemini() {
        #expect(isLimit(GeminiRealtimeSession.connectionEndEvent(afterGoAway: true, detail: "closed")))
        let drop = GeminiRealtimeSession.connectionEndEvent(afterGoAway: false, detail: "Socket is not connected")
        #expect(!isLimit(drop))
    }
}
