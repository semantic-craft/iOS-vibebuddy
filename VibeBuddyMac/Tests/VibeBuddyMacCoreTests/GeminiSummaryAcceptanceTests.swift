import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Bounded, explicit opt-in. Normal local checks neither load keys nor call a provider.
struct GeminiSummaryAcceptanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GEMINI_SUMMARY_ACCEPTANCE"] == "1"))
    func compareSummaryModels() async throws {
        let env = ProcessInfo.processInfo.environment
        let key = try #require(env["GEMINI_API_KEY"])
        let directory = URL(fileURLWithPath: try #require(env["GEMINI_ACCEPTANCE_OUTPUT"]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inputURL = URL(fileURLWithPath: try #require(env["GEMINI_ACCEPTANCE_INPUT"]))
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: inputURL))
        // A supplied, bounded set keeps real-session material outside the source tree.
        #expect((1...6).contains(samples.count))
        guard (1...6).contains(samples.count) else { return }
        let models = ["gemini-3.5-flash-lite", "gemini-3.8-flash"]
        let session = CompletionSummaryHTTP.session(timeout: 12)
        defer { session.invalidateAndCancel() }
        let http = CompletionSummaryHTTP(session: session)
        var results: [[String: Any]] = []
        for (index, sample) in samples.enumerated() {
            for offset in models.indices {
                let model = models[(index + offset) % models.count]
                let now = Date()
                let input = CompletionSummaryInput(sourceID: sample.sourceID, sessionID: sample.sessionID,
                    completionID: UUID().uuidString, turnID: sample.turnID, title: sample.title,
                    finalText: sample.finalText, completedAt: now, observedAt: now)
                let configuration = CompletionSummaryConfiguration(enabled: true, provider: .gemini,
                    modelID: model, language: sample.language == "en" ? .english : .chinese)
                let start = Date()
                let response = await http.generate(input: input, configuration: configuration,
                    key: key, timeout: 12, purpose: .notice)
                var row: [String: Any] = ["sample": index, "model": model,
                    "seconds": Date().timeIntervalSince(start), "sourceKind": sample.kind,
                    "failure": response.failure?.rawValue ?? "none"]
                row["text"] = response.text
                row["inputTokens"] = response.usage?.inputTokens
                row["outputTokens"] = response.usage?.outputTokens
                results.append(row)
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent("summary-results.json"), options: .atomic)
                print("Gemini summary sample=\(index) model=\(model) failure=\(response.failure?.rawValue ?? "none")")
            }
        }
        // Fail if either candidate never produced usable text; individual failures stay in the evidence.
        for model in models {
            #expect(results.contains { $0["model"] as? String == model && $0["text"] != nil })
        }
    }

    private struct Sample: Decodable {
        let sourceID: String
        let sessionID: String
        let turnID: String
        let title: String
        let finalText: String
        let language: String
        let kind: String
    }
}
