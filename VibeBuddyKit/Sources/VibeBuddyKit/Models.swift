import Foundation

/// Which coding agent a session belongs to. Source-agnostic by design — new
/// agents are added here without changing the rest of the wire model. Raw values
/// are stable wire strings; `claudeCode`/`codex` are kept for back-compat.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    case qwen
    case kimi
    case antigravity
    case grok
    case opencode
    case copilot
}

/// The three buckets the dashboard cares about.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case needsResponse   // ② your turn — permission / waiting for input
    case working         // ③ actively running
    case done            // ① turn ended, idle

    /// Display priority for the dashboard: lower sorts first (most urgent).
    public var attentionRank: Int {
        switch self {
        case .needsResponse: return 0
        case .working: return 1
        case .done: return 2
        }
    }
}

/// Why a session needs the user — only meaningful when `status == .needsResponse`.
public enum WaitKind: String, Codable, Sendable {
    case permission      // blocked on an approve/deny
    case question        // asked something / idle waiting for input
}

/// A tool use awaiting the user's approval from the phone. Present only while a
/// session is blocked on a remote approve/deny.
public struct PendingApproval: Codable, Sendable, Equatable {
    public let id: String
    public let tool: String
    public let commandPreview: String
    /// Rich detail for the phone's approval card. All optional and defaulted so
    /// older payloads decode and existing callers compile unchanged.
    public let command: String?      // full Bash command
    public let filePath: String?     // Edit/Write/Read target
    public let oldText: String?      // Edit: pre-image (for a diff)
    public let newText: String?      // Edit/Write: post-image / new content

    public init(id: String, tool: String, commandPreview: String,
                command: String? = nil, filePath: String? = nil,
                oldText: String? = nil, newText: String? = nil) {
        self.id = id
        self.tool = tool
        self.commandPreview = commandPreview
        self.command = command
        self.filePath = filePath
        self.oldText = oldText
        self.newText = newText
    }
}

/// A question the agent asked in the terminal, with optional pre-defined answers
/// that can be sent back by typing into the captured pane.
public struct QuestionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public let description: String?

    public init(id: String, label: String, value: String? = nil, description: String? = nil) {
        self.id = id
        self.label = label
        self.value = value ?? label
        self.description = description
    }
}

public struct PendingQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let prompt: String
    public let options: [QuestionOption]

    public init(id: String, prompt: String, options: [QuestionOption] = []) {
        self.id = id
        self.prompt = prompt
        self.options = options
    }
}

/// Identifies the terminal a session runs in, so the Mac can jump to it.
///
/// Three levels of precision, captured together by `hooks/capture-terminal.sh`
/// and consumed in that order by the jumper:
///
/// 1. **Pane** — `tmuxPane` (+ `tmux` socket) selects the pane inside a
///    multiplexer.
/// 2. **Surface** — `tty`, `itermSessionId`, `ghosttyTerminalId`,
///    `weztermPane`, `kittyWindowId` each identify one window/tab/split of a
///    specific terminal emulator, so the exact one can be raised.
/// 3. **App** — `termProgram`, or `hostBundleId` when the host sets no
///    `TERM_PROGRAM` at all (VS Code/Cursor tell each other apart only this
///    way, and the Claude desktop app sets none). Bringing the app forward is
///    the honest floor: it lands the user in the right application even when
///    the surface is unknowable.
///
/// Wire format is snake_case throughout, so the `/terminal` hook payload and
/// the phone's `AgentSession` JSON are the same shape. Empty strings decode as
/// `nil` — shell hooks find it easier to send `""` than to omit a key.
public struct TerminalRef: Codable, Sendable, Equatable {
    /// `$TERM_PROGRAM`: `ghostty`, `iTerm.app`, `apple_terminal`, `WezTerm`,
    /// `WarpTerminal`, `vscode`, or `kitty` (synthesized — kitty sets none).
    /// `nil` when the host exports nothing; `hostBundleId` covers that case.
    public let termProgram: String?
    /// Controlling tty without the `/dev/` prefix (`ttys003`). Terminal.app and
    /// iTerm2 both expose it per tab, which makes it an exact target there.
    public let tty: String?
    /// `$TMUX` — `socket,pid,session`; only the socket path is used.
    public let tmux: String?
    /// `$TMUX_PANE` — `%3`.
    public let tmuxPane: String?
    /// The UUID half of `$ITERM_SESSION_ID` (`w0t0p0:UUID`), which equals an
    /// iTerm2 session's `unique ID`.
    public let itermSessionId: String?
    /// `$WEZTERM_PANE` — an integer pane id for `wezterm cli activate-pane`.
    public let weztermPane: String?
    /// `$KITTY_WINDOW_ID` — an integer for `kitten @ focus-window --match id:N`.
    public let kittyWindowId: String?
    /// `$KITTY_LISTEN_ON` — the remote-control socket. Without it kitty's
    /// window cannot be addressed from outside, so the jump stops at the app.
    public let kittyListenOn: String?
    /// Ghostty's AppleScript `terminal` id, probed once at SessionStart while
    /// the surface is still focused (Ghostty exports no env var for it).
    public let ghosttyTerminalId: String?
    /// Bundle identifier of the nearest GUI ancestor process. The universal
    /// fallback: it names whatever app is hosting the session even when that
    /// app is not a terminal emulator we know.
    public let hostBundleId: String?
    /// Pid of that GUI ancestor. Diagnostic only — kept so a stale ref can be
    /// told from a live one.
    public let hostPid: Int?
    /// The session's working directory. Ghostty can be matched on it when the
    /// terminal id is missing or stale.
    public let cwd: String?

    public init(termProgram: String? = nil,
                tty: String? = nil,
                tmux: String? = nil,
                tmuxPane: String? = nil,
                itermSessionId: String? = nil,
                weztermPane: String? = nil,
                kittyWindowId: String? = nil,
                kittyListenOn: String? = nil,
                ghosttyTerminalId: String? = nil,
                hostBundleId: String? = nil,
                hostPid: Int? = nil,
                cwd: String? = nil) {
        self.termProgram = termProgram
        self.tty = tty
        self.tmux = tmux
        self.tmuxPane = tmuxPane
        self.itermSessionId = itermSessionId
        self.weztermPane = weztermPane
        self.kittyWindowId = kittyWindowId
        self.kittyListenOn = kittyListenOn
        self.ghosttyTerminalId = ghosttyTerminalId
        self.hostBundleId = hostBundleId
        self.hostPid = hostPid
        self.cwd = cwd
    }

    /// Bundle identifiers of the two emulators that expose a per-tab `tty`, and
    /// so are the only ones a bare tty can address below app level.
    private static let ttyAddressableBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    private static let ttyAddressableTermPrograms: Set<String> = ["apple_terminal", "iterm.app"]

    /// Whether this ref names a specific pane/tab/window rather than only an
    /// app. Drives the difference between `JumpOutcome.focused` and
    /// `.activatedApp`, and lets the UI promise only what it can deliver.
    ///
    /// A `tty` counts only under Terminal.app and iTerm2: they are the two
    /// emulators whose AppleScript dictionary exposes it per tab. Everywhere
    /// else the tty is real but unaddressable, and a jump can reach the app at
    /// best — so promising an exact target would be a lie.
    public var hasExactTarget: Bool {
        if tmuxPane != nil || itermSessionId != nil || weztermPane != nil
            || kittyWindowId != nil || ghosttyTerminalId != nil { return true }
        guard tty != nil else { return false }
        if let tp = termProgram?.lowercased(), Self.ttyAddressableTermPrograms.contains(tp) { return true }
        return hostBundleId.map(Self.ttyAddressableBundleIDs.contains) ?? false
    }

    /// Whether storing this ref would buy the jumper anything. A ref with no
    /// exact target, no `TERM_PROGRAM` and no host bundle id names nothing the
    /// jumper could act on — keeping it would only turn an honest "no terminal
    /// recorded" into a mystifying "couldn't locate this session's window".
    public var isActionable: Bool {
        hasExactTarget || termProgram != nil || hostBundleId != nil
    }

    /// This ref updated by a later capture: every field the new one carries
    /// wins, everything it is silent about is kept.
    ///
    /// Re-capture is not idempotent, which is why this exists. The
    /// `UserPromptSubmit` capture deliberately skips the Ghostty AppleScript
    /// probe (it is only correct while the surface is focused, i.e. at
    /// `SessionStart`), so a wholesale replace would erase
    /// `ghosttyTerminalId` on the session's next prompt.
    public func merging(_ newer: TerminalRef) -> TerminalRef {
        TerminalRef(
            termProgram: newer.termProgram ?? termProgram,
            tty: newer.tty ?? tty,
            tmux: newer.tmux ?? tmux,
            tmuxPane: newer.tmuxPane ?? tmuxPane,
            itermSessionId: newer.itermSessionId ?? itermSessionId,
            weztermPane: newer.weztermPane ?? weztermPane,
            kittyWindowId: newer.kittyWindowId ?? kittyWindowId,
            kittyListenOn: newer.kittyListenOn ?? kittyListenOn,
            ghosttyTerminalId: newer.ghosttyTerminalId ?? ghosttyTerminalId,
            hostBundleId: newer.hostBundleId ?? hostBundleId,
            hostPid: newer.hostPid ?? hostPid,
            cwd: newer.cwd ?? cwd
        )
    }

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case tty
        case tmux
        case tmuxPane = "tmux_pane"
        case itermSessionId = "iterm_session_id"
        case weztermPane = "wezterm_pane"
        case kittyWindowId = "kitty_window_id"
        case kittyListenOn = "kitty_listen_on"
        case ghosttyTerminalId = "ghostty_terminal_id"
        case hostBundleId = "host_bundle_id"
        case hostPid = "host_pid"
        case cwd
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ k: CodingKeys) -> String? {
            guard let v = try? c.decodeIfPresent(String.self, forKey: k), !v.isEmpty else { return nil }
            return v
        }
        termProgram = str(.termProgram)
        tty = str(.tty)
        tmux = str(.tmux)
        tmuxPane = str(.tmuxPane)
        itermSessionId = str(.itermSessionId)
        weztermPane = str(.weztermPane)
        kittyWindowId = str(.kittyWindowId)
        kittyListenOn = str(.kittyListenOn)
        ghosttyTerminalId = str(.ghosttyTerminalId)
        hostBundleId = str(.hostBundleId)
        hostPid = (try? c.decodeIfPresent(Int.self, forKey: .hostPid)) ?? nil
        cwd = str(.cwd)
    }
}

/// How a child of a parent session was observed. Raw values are stable wire strings.
public enum ChildAgentKind: String, Codable, Sendable {
    case subagent
    case task
    case teammate
}

/// Live child progress. `unknown` means identity or an end signal was insufficient.
public enum ChildAgentStatus: String, Codable, Sendable {
    case running
    case idle
    case completed
    case unknown
}

/// One teammate, subagent, or task attached to a parent session by a stable id.
public struct ChildAgent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: ChildAgentKind
    public var name: String?
    public var type: String?
    public var status: ChildAgentStatus
    public var lastActivity: String?
    public var updatedAt: Date

    public init(
        id: String,
        kind: ChildAgentKind,
        name: String? = nil,
        type: String? = nil,
        status: ChildAgentStatus,
        lastActivity: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.type = type
        self.status = status
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
    }
}

/// One coding-agent session, as broadcast to the phone.
public struct AgentSession: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let agent: AgentKind
    public var project: String
    public var branch: String?
    public var model: String?
    public var status: SessionStatus
    public var waitKind: WaitKind?
    public var pendingApproval: PendingApproval?
    public var pendingQuestion: PendingQuestion?
    public var terminalRef: TerminalRef?
    public var summary: String?
    public var tokens: Int?
    /// Context consumed on the last turn (input + cache_read + cache_creation)
    /// and the model's context window, for the phone's usage bar. Both optional.
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// The last turn / tool ended in an error (Bash non-zero exit, tool error,
    /// or a failure-looking Stop message). Optional so older payloads decode as
    /// "unknown"; drives the `agentStuck` cue and the buddy's worried face.
    public var failed: Bool?
    /// A clean completion result that has not yet been explicitly opened,
    /// selected, or jumped to. The Mac reducer is authoritative for this value.
    public var hasUnreadCompletion: Bool
    /// Cumulative tokens spent across this session's turns (input+output),
    /// accumulated by the reducer. Drives the estimated cost + budget alert.
    public var spentTokens: Int?
    /// The tool the agent is currently running (set on PreToolUse, cleared on
    /// PostToolUse / a new turn). Drives the Mac row's "Editing…/Searching…"
    /// activity line. Optional so older payloads decode as "unknown".
    public var activeTool: String?
    /// Stable evidence describing how this session was observed. Optional keeps
    /// snapshots from older Mac builds decodable by newer clients.
    public var observations: [ObservationEvidence]?
    /// Live teammate/subagent/task rows for this parent. Optional so older
    /// snapshots decode as "no topology yet"; recovery leaves this empty.
    public var childAgents: [ChildAgent]?
    /// True when a child event arrived without a stable identity. Optional so
    /// older payloads stay decodable and default to "not degraded".
    public var childTopologyDegraded: Bool?
    public var statusSince: Date
    public var updatedAt: Date

    public init(
        id: String,
        agent: AgentKind,
        project: String,
        branch: String? = nil,
        model: String? = nil,
        status: SessionStatus,
        waitKind: WaitKind? = nil,
        pendingApproval: PendingApproval? = nil,
        pendingQuestion: PendingQuestion? = nil,
        terminalRef: TerminalRef? = nil,
        summary: String? = nil,
        tokens: Int? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        failed: Bool? = nil,
        hasUnreadCompletion: Bool = false,
        spentTokens: Int? = nil,
        activeTool: String? = nil,
        observations: [ObservationEvidence]? = nil,
        childAgents: [ChildAgent]? = nil,
        childTopologyDegraded: Bool? = nil,
        statusSince: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.project = project
        self.branch = branch
        self.model = model
        self.status = status
        self.waitKind = waitKind
        self.pendingApproval = pendingApproval
        self.pendingQuestion = pendingQuestion
        self.terminalRef = terminalRef
        self.summary = summary
        self.tokens = tokens
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.failed = failed
        self.hasUnreadCompletion = hasUnreadCompletion
        self.spentTokens = spentTokens
        self.activeTool = activeTool
        self.observations = observations
        self.childAgents = childAgents
        self.childTopologyDegraded = childTopologyDegraded
        self.statusSince = statusSince
        self.updatedAt = updatedAt
    }

    /// Whether to treat this session as failed/stuck (Optional `failed` is "no").
    public var isStuck: Bool { failed == true }

    public var runningChildAgents: [ChildAgent] {
        (childAgents ?? []).filter { $0.status == .running }
    }

    public var runningChildAgentCount: Int { runningChildAgents.count }
}

/// Full state of every known session — sent on initial load and on reconnect.
public struct Snapshot: Codable, Sendable, Equatable {
    public var sessions: [AgentSession]
    public var serverTime: Date
    /// Mac-side source diagnostics, mirrored to iOS. Optional preserves wire
    /// compatibility with snapshots emitted before observability v2.
    public var observationDiagnostics: [AgentObservationDiagnostic]?

    public init(
        sessions: [AgentSession],
        serverTime: Date,
        observationDiagnostics: [AgentObservationDiagnostic]? = nil
    ) {
        self.sessions = sessions
        self.serverTime = serverTime
        self.observationDiagnostics = observationDiagnostics
    }
}

/// What the Mac encodes into the pairing QR; the phone scans and stores it.
/// `host` is a LAN IP today and a Tailscale 100.x IP later — same shape.
public struct PairingPayload: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String
    public var macName: String?

    public init(host: String, port: Int, token: String, macName: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.macName = macName
    }
}

/// What the paired iPhone reports back to the Mac after scanning the QR. The
/// APNs token is optional because the dashboard connection and push registration
/// can arrive in either order.
public struct DeviceRegistrationPayload: Codable, Sendable, Equatable {
    public var token: String?
    public var name: String?
    public var model: String?
    public var systemVersion: String?
    /// The phone's sound preferences, so the Mac's background push respects them.
    /// Optional so older payloads decode unchanged.
    public var playSound: Bool?
    public var quietMode: Bool?

    public init(token: String? = nil, name: String? = nil,
                model: String? = nil, systemVersion: String? = nil,
                playSound: Bool? = nil, quietMode: Bool? = nil) {
        self.token = token
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.playSound = playSound
        self.quietMode = quietMode
    }

    public var hasPushToken: Bool { token?.isEmpty == false }

    public var hasVisibleDeviceInfo: Bool {
        hasPushToken || name?.isEmpty == false || model?.isEmpty == false || systemVersion?.isEmpty == false
    }
}
