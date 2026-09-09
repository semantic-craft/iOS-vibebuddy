import Foundation

/// The wire work every HTTP speech vendor repeats: one bounded POST, no
/// redirects, no cache, and status/URL errors graded into the shared failure
/// type. Nothing the provider sends back is ever surfaced verbatim.
enum SpeechSynthesisHTTP {
    /// Summaries are two sentences; anything past this is not a summary.
    static let maximumBytes = 2_000_000
    static let timeout: TimeInterval = 15

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    static func post(_ url: URL, headers: [String: String], body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let session = session()
        defer { session.invalidateAndCancel() }
        do {
            try Task.checkCancellation()
            // No redirect follow-up: it could disclose the key or bill a second request.
            let (data, response) = try await session.data(for: request, delegate: NoSpeechRedirect())
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw SpeechSynthesisFailure.transport }
            guard (200..<300).contains(http.statusCode) else {
                throw switch http.statusCode {
                case 401, 403: SpeechSynthesisFailure.rejected
                case 429: SpeechSynthesisFailure.rateLimited
                default: SpeechSynthesisFailure.transport
                }
            }
            guard !data.isEmpty else { throw SpeechSynthesisFailure.emptyAudio }
            guard data.count <= maximumBytes else { throw SpeechSynthesisFailure.excessiveAudio }
            return data
        } catch let failure as SpeechSynthesisFailure { throw failure }
          catch is CancellationError { throw CancellationError() }
          catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw SpeechSynthesisFailure.timedOut
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed:
                throw SpeechSynthesisFailure.unreachable
            default: throw SpeechSynthesisFailure.transport
            }
        } catch { throw SpeechSynthesisFailure.transport }
    }

    /// A summary is a couple of sentences; refuse anything that is not.
    static func checkedText(_ text: String, apiKey: String) throws -> String {
        guard !apiKey.isEmpty else { throw SpeechSynthesisFailure.configuration }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 180 else { throw SpeechSynthesisFailure.configuration }
        return trimmed
    }

    /// Raw PCM needs a container before `AVAudioPlayer` will look at it.
    static func wav(pcm16: Data, sampleRate: Int, channels: Int = 1) -> Data {
        var header = Data()
        func u32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { header.append(contentsOf: $0) } }
        let byteRate = sampleRate * channels * 2
        header.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm16.count)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels)
        u32(sampleRate); u32(byteRate); u16(channels * 2); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(pcm16.count)
        return header + pcm16
    }
}

private final class NoSpeechRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
