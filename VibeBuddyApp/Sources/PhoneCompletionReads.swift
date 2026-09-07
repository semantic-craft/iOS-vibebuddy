import Foundation
import VibeBuddyKit

/// Durable exact-round reads. Contains identities and retry times, never credentials.
@MainActor
final class PhoneCompletionReads {
    struct Entry: Codable, Equatable {
        let request: CompletionReadRequest
        let epoch: String
        var failures = 0
        var retryAt = Date.distantPast
    }

    private(set) var entries: [Entry]
    private(set) var confirmed: Set<CompletionReadRequest> = []
    var onChange: (() -> Void)?
    private let url: URL
    private var jobs: [CompletionReadRequest: Task<Void, Never>] = [:]
    private var ticker: Task<Void, Never>?
    private var generation = UUID()

    init(url: URL = URL.applicationSupportDirectory.appending(path: "phone-completion-reads.json")) {
        self.url = url
        entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    func viewed(_ request: CompletionReadRequest, epoch: String) throws {
        guard !confirmed.contains(request), !entries.contains(where: { $0.request == request && $0.epoch == epoch }) else { return }
        var next = entries
        next.append(Entry(request: request, epoch: epoch))
        // Write through before making the record eligible for network delivery.
        try persist(next)
        entries = next
        onChange?()
    }

    func select(epoch: String) {
        pause()
        confirmed = []
        replace(entries.filter { $0.epoch == epoch })
    }

    func clear() {
        pause()
        confirmed = []
        replace([])
    }

    func pause() {
        generation = UUID()
        ticker?.cancel(); ticker = nil
        for job in jobs.values { job.cancel() }
        jobs = [:]
    }

    /// Only an authenticated full snapshot can retire a missing task or old round.
    func reconcile(_ snapshot: Snapshot, epoch: String) {
        guard let source = snapshot.sourceID else { return }
        let sessions = Dictionary(snapshot.sessions.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let previousConfirmed = confirmed
        confirmed = confirmed.filter {
            $0.sourceID == source && sessions[$0.sessionID]?.completionID == $0.completionID
        }
        replace(entries.filter { entry in
            guard entry.epoch == epoch, entry.request.sourceID == source,
                  let session = sessions[entry.request.sessionID],
                  session.completionID == entry.request.completionID else { return false }
            if !session.hasUnreadCompletion {
                confirmed.insert(entry.request)
                return false
            }
            return true
        })
        if previousConfirmed != confirmed { onChange?() }
    }

    func received(_ outcome: CompletionReadOutcome, request: CompletionReadRequest) {
        guard entries.contains(where: { $0.request == request }) else { return }
        switch outcome {
        case .accepted, .alreadyAcknowledged:
            confirmed.insert(request)
            replace(entries.filter { $0.request != request })
        case .staleCompletion, .sourceMismatch:
            replace(entries.filter { $0.request != request })
        case .failed, .unavailable:
            var next = entries
            if let index = next.firstIndex(where: { $0.request == request }) {
                next[index].failures = min(next[index].failures + 1, 6)
                next[index].retryAt = Date().addingTimeInterval(min(60, pow(2, Double(next[index].failures))))
            }
            replace(next)
        }
    }

    /// Each due item has its own request: a timeout cannot block another result.
    /// iOS suspension pauses execution; persisted work resumes on the next snapshot.
    func resume(pairing: PairingPayload, sourceID: String, epoch: String, client: DecisionClient) {
        let generation = self.generation
        sendDue(pairing: pairing, sourceID: sourceID, epoch: epoch, client: client, generation: generation)
        guard ticker == nil, !entries.isEmpty else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.entries.isEmpty {
                    self.ticker = nil
                    return
                }
                self.sendDue(pairing: pairing, sourceID: sourceID, epoch: epoch, client: client, generation: generation)
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func sendDue(pairing: PairingPayload, sourceID: String, epoch: String,
                         client: DecisionClient, generation: UUID) {
        guard self.generation == generation else { return }
        for entry in entries where entry.epoch == epoch && entry.request.sourceID == sourceID
            && entry.retryAt <= Date() && jobs[entry.request] == nil {
            let request = entry.request
            jobs[request] = Task { [weak self] in
                let result = await client.acknowledge(pairing, request: request)
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.jobs[request] = nil
                self.received(result, request: request)
            }
        }
    }

    private func persist(_ entries: [Entry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    private func replace(_ next: [Entry]) {
        guard next != entries else { return }
        // If cleanup cannot be saved, a restart may resend an idempotent exact
        // request. The next authoritative snapshot will reconcile it again.
        try? persist(next)
        entries = next
        onChange?()
    }
}
