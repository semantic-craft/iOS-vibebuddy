import Foundation
import Combine

public struct CompletionBodyRefresh: Equatable, Sendable {
    public let identity: CompletionReadRequest?
    public let context: String?
    public let textHint: String?
    public let notice: CompletionNotice?
    public let attempt: Int
    public let isActive: Bool

    public init(request: CompletionReadRequest?, context: String? = nil, attempt: Int = 0, isActive: Bool = true) {
        identity = request
        self.context = context
        self.attempt = attempt
        self.isActive = isActive
        textHint = nil
        notice = nil
    }

    public init(sourceID: String?, session: AgentSession, context: String? = nil,
                attempt: Int = 0, isActive: Bool = true) {
        if let sourceID, let completionID = session.completionID, session.status == .done {
            identity = CompletionReadRequest(sourceID: sourceID, sessionID: session.id, completionID: completionID)
        } else { identity = nil }
        self.context = context
        textHint = session.completionText
        notice = session.validatingCompletionNotice(sourceID: sourceID).completionNotice
        self.attempt = attempt
        self.isActive = isActive
    }
}

@MainActor
public final class CompletionBodyReader: ObservableObject {
    public enum State: Equatable {
        case loading
        case failed
        case body(CompletionBody)
    }

    @Published private var state: State = .loading
    private var refresh: CompletionBodyRefresh?
    private var generation = UUID()

    public init() {}

    public func state(for refresh: CompletionBodyRefresh) -> State {
        guard self.refresh?.identity == refresh.identity,
              self.refresh?.context == refresh.context else { return .loading }
        return state
    }

    public func body(for refresh: CompletionBodyRefresh) -> CompletionBody? {
        guard case .body(let body) = state(for: refresh) else { return nil }
        return body
    }

    public func load(_ refresh: CompletionBodyRefresh,
                     retryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)],
                     fetch: () async -> CompletionBody?) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        self.generation = generation
        let readable = body(for: refresh)?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        self.refresh = refresh
        if readable { return }
        guard !Task.isCancelled, refresh.isActive, let identity = refresh.identity else {
            state = .loading
            return
        }
        state = .loading
        for attempt in 0...retryDelays.count {
            let loaded = await fetch()
            guard !Task.isCancelled, self.generation == generation else { return }
            guard let loaded, loaded.sourceID == identity.sourceID,
                  loaded.sessionID == identity.sessionID, loaded.completionID == identity.completionID else {
                state = .failed
                return
            }
            state = .body(loaded)
            if loaded.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return }
            guard attempt < retryDelays.count else { return }
            do { try await Task.sleep(for: retryDelays[attempt]) }
            catch { return }
            guard self.generation == generation else { return }
        }
    }
}
