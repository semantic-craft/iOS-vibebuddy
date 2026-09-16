import Foundation
import Combine
import VibeBuddyKit

/// One in-memory, source-scoped paging chain. Refresh stages a replacement so
/// a changed transcript cannot splice into the text someone is reading.
@MainActor
final class PhoneHistoryReader: ObservableObject {
    @Published private(set) var page: HistoryPage?
    @Published private(set) var pending: HistoryPage?
    @Published private(set) var messages: [HistoryMessage] = []
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published private(set) var chainInvalid = false
    @Published private(set) var scrollTarget: String?
    @Published private(set) var scrollRevision = 0
    @Published private(set) var prependRevision = 0
    private(set) var scrollToTop = false
    private var task: Task<Void, Never>?
    private var attempt = UUID()
    var hasEarlier: Bool { !chainInvalid && page?.nextCursor != nil }

    func cancel(clear: Bool = false) {
        attempt = UUID(); task?.cancel(); task = nil; loading = false
        if clear { page = nil; pending = nil; messages = []; chainInvalid = true; failure = "source_changed" }
    }

    func load(earlier: Bool = false, beforePrepend: @escaping @MainActor () -> Void = {}, fetch: @escaping @MainActor (String?) async throws -> HistoryPage) {
        guard !loading, !earlier || hasEarlier else { return }
        loading = true; failure = nil
        let id = UUID(); attempt = id
        let cursor = earlier ? page?.nextCursor : nil
        task = Task {
            defer { if attempt == id { loading = false; task = nil } }
            do {
                var result: HistoryPage?
                for delay in 0...3 {
                    do { result = try await fetch(cursor); break }
                    catch let error as HistoryFailure where error.reason == "reader_busy" && delay < 3 {
                        try await Task.sleep(for: .seconds(min(5, 1 << delay)))
                    }
                }
                guard attempt == id, !Task.isCancelled, let result else { return }
                guard result.start >= 0, result.end >= result.start, result.end <= result.totalMessages,
                      result.messages.count == result.end - result.start,
                      Set(result.messages.map(\.id)).count == result.messages.count else { throw HistoryFailure("invalid_response") }
                if earlier {
                    guard let previous = page, result.sourceID == previous.sourceID, result.key == previous.key,
                          result.revision == previous.revision, result.end == previous.start,
                          Set(messages.map(\.id)).isDisjoint(with: result.messages.map(\.id)) else { throw HistoryFailure("revision_changed") }
                    beforePrepend()
                    messages.insert(contentsOf: result.messages, at: 0); page = result; prependRevision += 1
                } else if let previous = page {
                    guard result.sourceID == previous.sourceID, result.key == previous.key else { throw HistoryFailure("source_changed") }
                    if previous.revision != result.revision { pending = result; chainInvalid = true }
                    else if chainInvalid { pending = result }
                } else {
                    page = result; messages = result.messages; chainInvalid = false; scrollTarget = result.messages.last?.id; scrollToTop = false; scrollRevision += 1
                }
            } catch {
                guard attempt == id, !Task.isCancelled else { return }
                let reason = (error as? HistoryFailure)?.reason ?? "source_unavailable"
                failure = reason
                if reason == "source_changed" { page = nil; messages = []; pending = nil; chainInvalid = true }
                else if HistoryFailure(reason).invalidatesPages { chainInvalid = true }
            }
        }
    }

    func showPending() {
        guard let pending else { return }
        page = pending; messages = pending.messages; self.pending = nil
        chainInvalid = false; failure = nil; scrollTarget = pending.messages.last?.id; scrollToTop = false; scrollRevision += 1
    }
}
