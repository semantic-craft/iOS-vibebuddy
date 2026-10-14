import CryptoKit
import Foundation
import VibeBuddyKit

/// Presentation requests cannot claim, rewrite or redeliver completion notices.
public actor ContentPresentationService {
    /// Internal diagnostics preserve provider failures without widening the wire model.
    enum Outcome: Sendable, Equatable {
        case generated(String)
        case failed(CompletionSummaryFailure)
        case atCapacity

        var text: String? {
            if case .generated(let text) = self { return text }
            return nil
        }
        var reason: String? {
            switch self {
            case .generated: nil
            case .failed(let failure): failure.rawValue
            case .atCapacity: "atCapacity"
            }
        }
    }
    private struct Cached {
        let outcome: Outcome
        let expiresAt: Date
    }
    private var cli = GeminiCLI()
    func setCLIRunnerForTesting(_ runner: @escaping GeminiCLI.Runner) { cli.run = runner }
    private let http: CompletionSummaryHTTP
    private let key: @Sendable (VoiceProvider) -> String?
    private var cache: [String: Cached] = [:]
    private var order: [String] = []
    private var pending: [String: Task<Outcome, Never>] = [:]
    private var waiters: [UUID: Set<UUID>] = [:]
    private var generations: [String: UUID] = [:]
    private var activeGenerations: Set<UUID> = []

    public init(session: URLSession? = nil,
                key: @escaping @Sendable (VoiceProvider) -> String? = { CompletionSummaryConfiguration.apiKey(for: $0) }) {
        http = .init(session: session ?? CompletionSummaryHTTP.session(timeout: 30))
        self.key = key
    }

    public func generate(_ input: CompletionSummaryInput, purpose: SummaryPurpose,
                         configuration: CompletionSummaryConfiguration) async -> String? {
        let result = await outcome(input, purpose: purpose, configuration: configuration)
        if let reason = result.reason {
            Self.diagnose(stage: "generation", reason: reason)
        }
        return result.text
    }

    /// Only callers supplying a fixed diagnostic or a CompletionBody reason use this.
    /// Never log provider bodies, input text, titles, paths, or credentials.
    static func diagnose(stage: String, reason: String) {
        FileHandle.standardError.write(Data("ContentPresentation unavailable stage=\(stage) reason=\(reason)\n".utf8))
    }

    func outcome(_ input: CompletionSummaryInput, purpose: SummaryPurpose,
                 configuration: CompletionSummaryConfiguration) async -> Outcome {
        guard !Task.isCancelled else { return .failed(.cancelled) }
        guard purpose != .notice,
              !input.sourceID.isEmpty, !input.sessionID.isEmpty, !input.completionID.isEmpty,
              !input.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              input.title.count + input.finalText.count <= 50_000 else { return .failed(.invalidInput) }
        var config = configuration
        config.enabled = true
        if let failure = config.configurationFailure { return .failed(failure) }
        let fields = [input.sourceID, input.sessionID, input.completionID, input.turnID ?? "",
                      input.title, input.finalText, purpose.rawValue, config.presentationRevision,
                      purpose == .speech ? config.speechStyle.rawValue : ""]
        let data = Data(fields.map { "\($0.utf8.count):\($0)" }.joined().utf8)
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let result = cache[id], result.expiresAt > Date() { return result.outcome }
        cache.removeValue(forKey: id)
        order.removeAll { $0 == id }
        if let task = pending[id], let generation = generations[id] {
            let result = await sharedResult(task, id: id, generation: generation, local: config.usesGeminiCLI)
            return Task.isCancelled ? .failed(.cancelled) : result
        }
        // Bound provider work as well as retained results. Failed attempts remain cached.
        // Three, not two: the phone and the Mac may word one completion in
        // different personas, which are separate generations.
        guard activeGenerations.count < 3 else { return .atCapacity }
        let http = self.http, key = self.key, captured = config, cli = self.cli
        let secret = captured.requiresAPIKey ? captured.provider.flatMap(key) : nil
        if captured.requiresAPIKey && (secret?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) { return .failed(.missingKey) }
        let task = Task.detached { () -> Outcome in
            let result = captured.usesGeminiCLI
                ? await cli.generate(input: input, configuration: captured, timeout: 30, purpose: purpose)
                : await http.generate(input: input, configuration: captured, key: secret ?? "", timeout: 30, purpose: purpose)
            if let failure = result.failure { return .failed(failure) }
            guard let text = result.text, !text.isEmpty else { return .failed(.emptyOutput) }
            return .generated(text)
        }
        let generation = UUID()
        pending[id] = task
        generations[id] = generation
        activeGenerations.insert(generation)
        let result = await sharedResult(task, id: id, generation: generation, local: captured.usesGeminiCLI)
        activeGenerations.remove(generation)
        if generations[id] == generation {
            pending.removeValue(forKey: id)
            generations.removeValue(forKey: id)
            if result != .failed(.cancelled) {
                cache[id] = Cached(outcome: result, expiresAt: Date().addingTimeInterval(result.text == nil ? 15 : 900))
                order.append(id)
            }
        }
        while order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }
        return Task.isCancelled ? .failed(.cancelled) : result
    }
    private func sharedResult(_ task: Task<Outcome, Never>, id: String, generation: UUID, local: Bool) async -> Outcome {
        let waiter = UUID()
        waiters[generation, default: []].insert(waiter)
        let result = await withTaskCancellationHandler { await task.value } onCancel: {
            if local { Task { await self.releaseWaiter(id, generation: generation, task: task, waiter: waiter, cancelled: true) } }
        }
        releaseWaiter(id, generation: generation, task: task, waiter: waiter, cancelled: false)
        return result
    }

    private func releaseWaiter(_ id: String, generation: UUID, task: Task<Outcome, Never>, waiter: UUID, cancelled: Bool) {
        guard waiters[generation]?.remove(waiter) != nil else { return }
        if waiters[generation]?.isEmpty == true {
            waiters.removeValue(forKey: generation)
            if cancelled {
                // Stop admitting subscribers before cancelling; count the dying worker
                // until it unwinds, and never let it remove or cache over a replacement.
                if generations[id] == generation {
                    pending.removeValue(forKey: id)
                    generations.removeValue(forKey: id)
                }
                task.cancel()
            }
        }
    }
}
