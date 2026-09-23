import Foundation

/// Which provider signals mean "this connection reached its per-connection
/// limit" (`RealtimeVoiceEvent.providerLimitReached`, ADR-0001 §Provider limit).
/// Each rule needs an explicit provider signal; a network drop, an auth or quota
/// error, or a server fault stays a failure. Sources and the verified behavior
/// are recorded in `docs/planning/backlog/realtime-verify/issues/02-provider-limit-redial.md`.
enum ProviderLimitSignal {
    /// Qwen's realtime endpoint closes a session after 120 minutes (documented
    /// for the Omni-Realtime models on the same `/api-ws/v1/realtime` endpoint;
    /// the Qwen-Audio 3.0 page names no duration and no error event).
    static let qwenSessionLimit: TimeInterval = 120 * 60
    /// Clock skew between our connect time and the server's session start.
    static let qwenSessionLimitMargin: TimeInterval = 60

    /// OpenAI Realtime: `error.code == "session_expired"` at its 60-minute cap.
    /// The code, not the message text, is the signal.
    static func isOpenAIRealtimeLimit(error event: [String: Any]) -> Bool {
        (event["error"] as? [String: Any])?["code"] as? String == "session_expired"
    }

    /// GPT-Live: `session.closed` with `reason: "expired"` ("the session reached
    /// its duration limit"). `connection_lost`, `content`, `remote_hangup` and
    /// `close_requested` are other endings.
    static func isOpenAILiveLimit(closed event: [String: Any]) -> Bool {
        event["reason"] as? String == "expired"
    }

    /// Qwen sends no limit event: the server closes the WebSocket. Only a close
    /// frame the server actually sent, on a connection that has lived to the
    /// documented limit, counts. An earlier close, or a drop without a close
    /// frame, is not the limit.
    static func isQwenLimit(serverCloseCode: URLSessionWebSocketTask.CloseCode, connectedFor: TimeInterval) -> Bool {
        serverCloseCode != .invalid && serverCloseCode != .abnormalClosure
            && connectedFor >= qwenSessionLimit - qwenSessionLimitMargin
    }
}
