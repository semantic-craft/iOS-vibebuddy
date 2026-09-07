import Foundation
import VibeBuddyKit

/// Own one instance in the source Mac process. The notification coordinator must persist claims/decisions
/// before submitting, suppress historical replay after restart, and recheck lifecycle/recipient eligibility
/// before delivery. This service owns only generation, with process-lifetime deduplication.
public actor CompletionSummaryService {
    public static let deadlineSeconds: TimeInterval = 12
    public static let maximumInputCharacters = 12_000
    public static let maximumConcurrentRequests = 2

    private struct Job {
        let token: UUID
        let input: CompletionSummaryInput
        let configuration: CompletionSummaryConfiguration
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<CompletionSummaryResult, Never>
        let timer: Task<Void, Never>
    }
    private let http: CompletionSummaryHTTP
    private let key: @Sendable (VoiceProvider) -> String?
    private var claimed: Set<CompletionSummaryIdentity> = []
    private var jobs: [CompletionSummaryIdentity: Job] = [:]
    private var queue: [CompletionSummaryIdentity] = []
    // A cancelled HTTP operation still occupies its slot until URLSession actually unwinds.
    private var workers: [CompletionSummaryIdentity: Task<Void, Never>] = [:]

    public init(session: URLSession? = nil,
                key: @escaping @Sendable (VoiceProvider) -> String? = { $0.apiKey }) {
        self.http = .init(session: session ?? CompletionSummaryHTTP.session())
        self.key = key
    }

    public func generate(_ input: CompletionSummaryInput, configuration: CompletionSummaryConfiguration) async -> CompletionSummaryResult {
        let token = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return result(input, failure: .cancelled) }
            let now = Date()
            guard !input.sourceID.isEmpty, !input.sessionID.isEmpty, !input.completionID.isEmpty,
                  input.completedAt.timeIntervalSince1970.isFinite, input.observedAt.timeIntervalSince1970.isFinite,
                  input.completedAt <= input.observedAt, input.observedAt <= now else { return result(input, failure: .invalidInput) }
            guard claimed.insert(input.identity).inserted else { return result(input, failure: .duplicate) }
            let remaining = input.completedAt.addingTimeInterval(Self.deadlineSeconds).timeIntervalSince(now)
            guard remaining > 0 else { return result(input, failure: .expired) }
            if let failure = configuration.configurationFailure { return result(input, failure: failure) }
            guard !input.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return result(input, failure: .invalidInput) }
            guard input.finalText.count + input.title.count <= Self.maximumInputCharacters else { return result(input, failure: .resultTooLong) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(remaining))
            return await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    await self?.stop(input.identity, token: token, failure: .expired)
                }
                jobs[input.identity] = Job(token: token, input: input, configuration: configuration,
                                           deadline: deadline, continuation: continuation, timer: timer)
                queue.append(input.identity)
                drain()
            }
        } onCancel: {
            Task { await self.stop(input.identity, token: token, failure: .cancelled) }
        }
    }

    /// For a new turn, read acknowledgement, unfollow or source invalidation. Never permits regeneration.
    public func cancel(_ identity: CompletionSummaryIdentity) { stop(identity, token: nil, failure: .cancelled) }

    private func stop(_ identity: CompletionSummaryIdentity, token: UUID?, failure: CompletionSummaryFailure) {
        guard let job = jobs[identity], token == nil || job.token == token else { return }
        jobs.removeValue(forKey: identity)
        queue.removeAll { $0 == identity }
        job.timer.cancel()
        workers[identity]?.cancel()
        job.continuation.resume(returning: result(job.input, failure: failure))
        drain()
    }

    private func drain() {
        while workers.count < Self.maximumConcurrentRequests, !queue.isEmpty {
            let identity = queue.removeFirst()
            guard let job = jobs[identity] else { continue }
            guard remaining(job) > 0 else {
                jobs.removeValue(forKey: identity)
                job.timer.cancel()
                job.continuation.resume(returning: result(job.input, failure: .expired))
                continue
            }
            let http = self.http, key = self.key
            // Keep Keychain and JSON work off this actor so expiry/cancellation can return on time.
            workers[identity] = Task.detached { [weak self] in
                let response: CompletionSummaryResponse
                if Task.isCancelled || ContinuousClock.now >= job.deadline {
                    response = .init(failure: .expired)
                } else if let apiKey = key(job.configuration.provider), !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let budget = min(job.input.completedAt.addingTimeInterval(Self.deadlineSeconds).timeIntervalSinceNow,
                                     Self.seconds(ContinuousClock.now.duration(to: job.deadline)))
                    if budget > 0, !Task.isCancelled {
                        response = await http.generate(input: job.input, configuration: job.configuration, key: apiKey, timeout: budget)
                    } else { response = .init(failure: .expired) }
                } else { response = .init(failure: .missingKey) }
                await self?.finished(identity, response: response)
            }
        }
    }

    private func finished(_ identity: CompletionSummaryIdentity, response: CompletionSummaryResponse) {
        workers.removeValue(forKey: identity)
        if let job = jobs.removeValue(forKey: identity) {
            job.timer.cancel()
            job.continuation.resume(returning: remaining(job) > 0
                ? result(job.input, response: response)
                : result(job.input, failure: .expired, usage: response.usage))
        }
        drain()
    }

    private func remaining(_ job: Job) -> TimeInterval {
        min(job.input.completedAt.addingTimeInterval(Self.deadlineSeconds).timeIntervalSinceNow,
            Self.seconds(ContinuousClock.now.duration(to: job.deadline)))
    }

    private nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func result(_ input: CompletionSummaryInput, failure: CompletionSummaryFailure,
                        usage: CompletionSummaryUsage? = nil) -> CompletionSummaryResult {
        result(input, response: .init(usage: usage, failure: failure))
    }

    private func result(_ input: CompletionSummaryInput, response: CompletionSummaryResponse) -> CompletionSummaryResult {
        let age = Date().timeIntervalSince(input.completedAt)
        return .init(identity: input.identity, text: response.text, usage: response.usage, failure: response.failure,
                     completionLatency: age.isFinite ? max(0, age) : 0)
    }
}
