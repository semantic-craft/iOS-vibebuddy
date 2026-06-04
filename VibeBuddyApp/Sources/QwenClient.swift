import Foundation

struct ChatMessage: Codable, Equatable {
    let role: String    // "system" | "user" | "assistant"
    let content: String
}

enum VoiceBrainError: Error { case noKey, http(Int), badResponse }

/// The conversational brain. Injectable so the voice flow can be tested with a fake.
protocol VoiceBrain: Sendable {
    func reply(messages: [ChatMessage]) async throws -> String
}

/// Alibaba Bailian / DashScope, via the OpenAI-compatible chat-completions endpoint.
/// Text-in / text-out (ASR and TTS are on-device), so this is a single plain POST.
struct QwenClient: VoiceBrain {
    var apiKey: String?
    var model: String
    var useIntl: Bool

    private var endpoint: URL {
        let host = useIntl ? "dashscope-intl.aliyuncs.com" : "dashscope.aliyuncs.com"
        return URL(string: "https://\(host)/compatible-mode/v1/chat/completions")!
    }

    func reply(messages: [ChatMessage]) async throws -> String {
        guard let apiKey, !apiKey.isEmpty else { throw VoiceBrainError.noKey }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: model, messages: messages, stream: false))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VoiceBrainError.badResponse }
        guard http.statusCode == 200 else { throw VoiceBrainError.http(http.statusCode) }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let text = decoded.choices.first?.message.content else { throw VoiceBrainError.badResponse }
        return text
    }

    private struct RequestBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
    }
    private struct ResponseBody: Decodable {
        struct Choice: Decodable { let message: ChatMessage }
        let choices: [Choice]
    }
}
