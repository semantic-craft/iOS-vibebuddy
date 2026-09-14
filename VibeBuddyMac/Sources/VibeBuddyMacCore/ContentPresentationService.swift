import CryptoKit
import Foundation
import VibeBuddyKit

/// Presentation requests cannot claim, rewrite or redeliver completion notices.
public actor ContentPresentationService {
    private struct Cached {
        let text: String?
        let expiresAt: Date
    }
    private let http: CompletionSummaryHTTP
    private let key: @Sendable (VoiceProvider) -> String?
    private var cache: [String: Cached] = [:]
    private var order: [String] = []
    private var pending: [String: Task<String?, Never>] = [:]

    public init(session: URLSession? = nil,
                key: @escaping @Sendable (VoiceProvider) -> String? = { CompletionSummaryConfiguration.apiKey(for: $0) }) {
        http = .init(session: session ?? CompletionSummaryHTTP.session(timeout: 30))
        self.key = key
    }

    public func generate(_ input: CompletionSummaryInput, purpose: SummaryPurpose,
                         configuration: CompletionSummaryConfiguration) async -> String? {
        guard !Task.isCancelled, purpose != .notice,
              !input.sourceID.isEmpty, !input.sessionID.isEmpty, !input.completionID.isEmpty,
              !input.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.title.count + input.finalText.count <= 50_000 else { return nil }
        var config = configuration
        config.enabled = true
        guard config.configurationFailure == nil else { return nil }
        let fields = [input.sourceID, input.sessionID, input.completionID, input.turnID ?? "",
                      input.title, input.finalText, purpose.rawValue, config.presentationRevision]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let result = cache[id], result.expiresAt > Date() { return result.text }
        cache.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if let task = pending[id] {
            let text = await task.value
            return Task.isCancelled ? nil : text
        }
        // Bound provider work as well as retained results. Failed attempts remain cached.
        guard pending.count < 2 else { return nil }
        let http = self.http, key = self.key, captured = config
        guard let provider = captured.provider,
              let secret = key(provider), !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let task = Task.detached { () -> String? in
            let result = await http.generate(input: input, configuration: captured, key: secret, timeout: 30, purpose: purpose)
            return result.failure == nil ? result.text : nil
        }
        pending[id] = task
        let text = await task.value
        pending.removeValue(forKey: id)
        cache[id] = Cached(text: text, expiresAt: Date().addingTimeInterval(text == nil ? 15 : 900))
        order.append(id)
        while order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }
        return Task.isCancelled ? nil : text
    }
}
