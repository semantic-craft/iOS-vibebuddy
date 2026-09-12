import Foundation
import VibeBuddyKit

/// Starts a new Cursor task for a dispatch: `cursor-agent -- <prompt>` in the
/// requested directory, in a terminal window.
///
/// A terminal rather than `--print`: a headless Cursor run has nowhere to show
/// its own prompts, and Cursor still raises them for anything vibebuddy's hooks
/// answer with `allow`. In a window the run is watchable on the Mac and
/// answerable from the phone, which is the combination the rest of vibebuddy
/// assumes.
///
/// Unlike `claude --bg`, the CLI prints no id we could read back, so the new
/// conversation is identified the way Cursor itself names it: the agent
/// transcript that appears under the project directory moments after launch.
/// When none appears in time the dispatch is still reported as started — the
/// terminal window is the evidence — with no id to match a row on yet.
public actor CursorLauncher {
    private let projectsRoot: URL
    private let executable: URL?
    private let terminalProgram: @Sendable () async -> String?
    private let start: @Sendable (String, String, String?) async -> Bool
    private let identifyTimeout: TimeInterval
    private var signedIn: Bool?

    public init(projectsRoot: URL = CursorTranscripts.projectsRoot(),
                executable: URL? = CursorCLI.resolveExecutable(),
                terminalProgram: @escaping @Sendable () async -> String? = { nil },
                identifyTimeout: TimeInterval = 8,
                start: (@Sendable (String, String, String?) async -> Bool)? = nil) {
        self.projectsRoot = projectsRoot
        self.executable = executable
        self.terminalProgram = terminalProgram
        self.identifyTimeout = identifyTimeout
        let resolved = executable
        self.start = start ?? { prompt, cwd, term in
            await CursorCLI.start(prompt: prompt, executable: resolved, cwd: cwd, preferring: term)
        }
    }

    /// True when `cursor-agent` is installed *and* signed in. Cached: the CLI
    /// keeps its own credentials, and probing them costs a subprocess, which
    /// must not happen on every snapshot.
    public func isSupported() async -> Bool {
        if let signedIn { return signedIn }
        guard let executable else { signedIn = false; return false }
        let ok = await CursorCLI.isSignedIn(executable: executable)
        signedIn = ok
        return ok
    }

    /// Forget the cached sign-in verdict, so a `cursor-agent login` the person
    /// has just done is picked up without restarting vibebuddy.
    public func invalidate() { signedIn = nil }

    public func dispatch(_ request: DispatchRequest) async -> DispatchOutcome {
        guard request.agent == .cursor else {
            return .unsupported("This launcher only starts Cursor sessions")
        }
        guard executable != nil else {
            return .unavailable("The Cursor CLI (cursor-agent) is not installed on this Mac")
        }
        guard await isSupported() else {
            return .unavailable("The Cursor CLI is not signed in — run `cursor-agent login` on this Mac")
        }
        let before = conversationIDs(inProject: request.cwd)
        guard await start(request.prompt, request.cwd, await terminalProgram()) else {
            return .unavailable("Couldn't open a terminal running cursor-agent")
        }
        let deadline = Date().addingTimeInterval(identifyTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if let fresh = conversationIDs(inProject: request.cwd).subtracting(before).sorted().first {
                return .started(sessionID: fresh)
            }
        }
        return .started(sessionID: "")
    }

    /// The conversations Cursor already has a transcript for in this project.
    private func conversationIDs(inProject path: String) -> Set<String> {
        Set(CursorTranscripts.discover(root: projectsRoot)
            .filter { $0.project == path }
            .map(\.conversationID))
    }
}
