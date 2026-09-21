import Foundation
import VibeBuddyKit

/// Validates and starts a task, then records its continuation only after launch succeeds.
public struct TaskDispatcher: Sendable {
    public enum DirectoryPolicy: Sendable { case knownSession, userSelected }
    public enum Failure: Error, Equatable, Sendable {
        case directoryUnavailable
        case unknownDirectory
        case staleContinuation
        case unsupportedAgent(AgentKind)
    }

    private let store: SessionStore
    private let codex: CodexAppServerMonitor?
    private let claude: ClaudeBackgroundLauncher
    private let cursor: CursorLauncher
    private let cursorACP: CursorACPMonitor?
    private let grokACP: GrokACPMonitor?
    private let launchOverride: (@Sendable (DispatchRequest) async -> DispatchOutcome)?

    public init(store: SessionStore, codex: CodexAppServerMonitor? = nil,
                claude: ClaudeBackgroundLauncher = ClaudeBackgroundLauncher(),
                cursor: CursorLauncher = CursorLauncher(), cursorACP: CursorACPMonitor? = nil,
                grokACP: GrokACPMonitor? = nil,
                launchOverride: (@Sendable (DispatchRequest) async -> DispatchOutcome)? = nil) {
        self.store = store
        self.codex = codex
        self.claude = claude
        self.cursor = cursor
        self.cursorACP = cursorACP
        self.grokACP = grokACP
        self.launchOverride = launchOverride
    }

    public func dispatch(_ request: DispatchRequest, directory: DirectoryPolicy = .knownSession) async -> Result<DispatchOutcome, Failure> {
        switch directory {
        case .userSelected:
            var isDirectory: ObjCBool = false
            guard request.cwd.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: request.cwd, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return .failure(.directoryUnavailable) }
        case .knownSession:
            guard await store.isKnownDirectory(request.cwd) else { return .failure(.unknownDirectory) }
        }
        guard await store.acceptsContinuation(request.continuation) else { return .failure(.staleContinuation) }
        var request = request
        request.prompt = ContinueWith.promptForDispatch(request.prompt, handoffPath: request.continuation?.handoffPath, checkout: request.cwd)
        let outcome: DispatchOutcome
        if let launchOverride {
            outcome = await launchOverride(request)
        } else {
            switch request.agent {
            case .codex:
                guard let codex else { return .failure(.unsupportedAgent(request.agent)) }
                outcome = await codex.dispatch(request)
            case .claudeCode:
                outcome = await claude.dispatch(request)
            case .cursor:
                if let cursorACP, await cursorACP.isSupported() {
                    outcome = await cursorACP.dispatch(request)
                } else {
                    outcome = await cursor.dispatch(request)
                }
            case .grok:
                // Grok Build has no detached launcher: a hosted ACP process is
                // the only way a phone-started session can be observed and
                // answered (ADR-0030).
                guard let grokACP else { return .failure(.unsupportedAgent(request.agent)) }
                outcome = await grokACP.dispatch(request)
            default:
                return .failure(.unsupportedAgent(request.agent))
            }
        }
        if case .started(let id) = outcome, let continuation = request.continuation,
           let receiverKey = ContinueWith.sessionKey(agent: request.agent, id: id) {
            await store.recordContinuation(receiverKey: receiverKey, sourceKey: continuation.sourceKey,
                                           handoffPath: continuation.handoffPath)
        }
        return .success(outcome)
    }
}
