import Foundation

/// Claude Code: lifecycle hooks and the status line wrapper in
/// `settings.json` (`$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/`).
///
/// Status handlers are fire-and-forget (`async: true`) and never enter the
/// agent's critical path; the opt-in approval gate is synchronous. Claude Code
/// validates `settings.json` as a whole and skips the entire file when it
/// meets an event name it does not know, so events are gated by the installed
/// version (`eventMinimums`).
struct ClaudeHooks {
    let paths: HookPaths
    let context: HookInstaller.Context
    /// The installed CLI; nil when unknown, which selects the conservative set.
    let version: ClaudeCodeVersion?

    var files: HookFileStore { HookFileStore(paths: paths) }

    /// High-signal lifecycle events and the release that introduced each (from
    /// the public Claude Code changelog). Deliberately not registered:
    /// WorktreeCreate (configuring it *replaces* Claude's own worktree
    /// creation), WorktreeRemove, DirectoryAdded (would widen the
    /// recent-directories allowlist), MessageDisplay, Setup,
    /// UserPromptExpansion, InstructionsLoaded, ConfigChange, FileChanged,
    /// PreModelSwitch.
    static let eventMinimums: [(event: String, since: ClaudeCodeVersion)] = [
        ("SessionStart", .init(1, 0, 62)),
        ("UserPromptSubmit", .init(1, 0, 54)),
        ("PreToolUse", .init(0, 0, 0)),
        ("PermissionRequest", .init(2, 0, 45)),
        ("PermissionDenied", .init(2, 1, 89)),
        ("PostToolUse", .init(0, 0, 0)),
        // No "added" entry in the changelog; 2.1.119 is the first release
        // that names it.
        ("PostToolUseFailure", .init(2, 1, 119)),
        ("Notification", .init(0, 0, 0)),
        // No changelog entry at all; 2.1.270 is the oldest binary verified to
        // carry it. Too high only costs the event on older CLIs.
        ("PostToolBatch", .init(2, 1, 270)),
        ("Elicitation", .init(2, 1, 76)),
        ("ElicitationResult", .init(2, 1, 76)),
        ("SubagentStart", .init(2, 0, 43)),
        ("SubagentStop", .init(1, 0, 41)),
        ("TeammateIdle", .init(2, 1, 33)),
        ("TaskCreated", .init(2, 1, 84)),
        ("TaskCompleted", .init(2, 1, 33)),
        ("PreCompact", .init(1, 0, 48)),
        ("PostCompact", .init(2, 1, 76)),
        ("Stop", .init(0, 0, 0)),
        ("StopFailure", .init(2, 1, 78)),
        ("PostModelSwitch", .init(2, 1, 251)),
        ("CwdChanged", .init(2, 1, 83)),
        ("SessionEnd", .init(1, 0, 85)),
    ]
    /// With no version to go on, assume a CLI as old as the approval
    /// contract itself: every core event, none of the recent ones.
    static let unknownVersionFloor = ClaudeCodeVersion(2, 0, 45)
    /// `args` (exec form, no shell) arrived in 2.1.139; older releases ignore
    /// it and shell-parse `command`, which breaks on a path with a space.
    static let execFormMinimum = ClaudeCodeVersion(2, 1, 139)
    /// Claude validates the PermissionRequest `decision` reply from 2.1.257;
    /// an older CLI waits silently on it, so the gate stays on PreToolUse.
    static let permissionRequestMinimum = ClaudeCodeVersion(2, 1, 257)
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied"]
    static let captureEvents = ["SessionStart", "UserPromptSubmit"]
    static let approvalTimeout = 30
    static let questionMatcher = "AskUserQuestion"
    static let statusLineMarker = "vibebuddy-statusline.sh"

    static func statusEvents(for version: ClaudeCodeVersion?) -> [String] {
        let effective = version ?? unknownVersionFloor
        return eventMinimums.filter { effective >= $0.since }.map(\.event)
    }

    // MARK: - Commands

    var forwarderPath: String { paths.script("vibebuddy-forward.sh").path }
    var approvalCommand: String { ShellWords.quoted(paths.script("approval-hook.sh").path) }
    /// The inert `claude` argument keeps Grok's `[compat.claude]` bridge from
    /// resolving a quoted, argument-less command as a literal path.
    var captureCommand: String { ShellWords.quoted(paths.script("capture-terminal.sh").path) + " claude" }
    var statusLineCommand: String { ShellWords.quoted(paths.script("vibebuddy-statusline.sh").path) }
    var usesExecForm: Bool { version.map { $0 >= Self.execFormMinimum } ?? false }

    func statusGroup(_ event: String) -> OrderedJSON {
        let hook: OrderedJSON = usesExecForm
            ? .obj(["type": .string("command"), "command": .string(forwarderPath),
                    "args": .array([.string("claude")]), "timeout": .int(5), "async": .bool(true)])
            : .obj(["type": .string("command"), "command": .string(ShellWords.quoted(forwarderPath) + " claude"),
                    "timeout": .int(5), "async": .bool(true)])
        return Self.toolEvents.contains(event)
            ? .obj(["matcher": .string("*"), "hooks": .array([hook])])
            : .obj(["hooks": .array([hook])])
    }

    var captureGroup: OrderedJSON {
        .obj(["hooks": .array([.obj(["type": .string("command"), "command": .string(captureCommand),
                                     "timeout": .int(5), "async": .bool(true)])])])
    }

    func gateGroup(matcher: String) -> OrderedJSON {
        .obj(["matcher": .string(matcher),
              "hooks": .array([.obj(["type": .string("command"), "command": .string(approvalCommand),
                                     "timeout": .int(Self.approvalTimeout)])])])
    }

    // MARK: - Recognition (any path: bundle, checkout, stable bin)

    private func command(_ hook: OrderedJSON) -> String { hook["command"]?.stringValue ?? "" }

    func isStatus(_ hook: OrderedJSON) -> Bool {
        let value = command(hook)
        // The inline-curl form an early installer wrote.
        return value.contains("vibebuddy-forward.sh") || value.contains("127.0.0.1:\(context.port)/hook")
    }
    func isApproval(_ hook: OrderedJSON) -> Bool { command(hook).contains("approval-hook.sh") }
    func isCapture(_ hook: OrderedJSON) -> Bool { command(hook).contains("capture-terminal.sh") }
    func isOurs(_ hook: OrderedJSON) -> Bool {
        isStatus(hook) || isApproval(hook) || isCapture(hook) || context.knownCommands.contains(command(hook))
    }
    func isQuestionGate(_ group: OrderedJSON) -> Bool {
        groupContains(group, where: isApproval) && group["matcher"]?.stringValue == Self.questionMatcher
    }
    static func isWrapper(_ statusLine: OrderedJSON?) -> Bool {
        statusLine?["command"]?.stringValue?.contains(statusLineMarker) == true
    }

    // MARK: - Run

    func load() throws -> (OrderedJSON, Bool) {
        let (data, existed) = try loadJSONObject(paths.claudeSettings, files: files)
        if let hooks = data["hooks"] {
            guard let events = hooks.members else {
                throw HookInstallerError.invalidConfig(paths.claudeSettings.path, "\"hooks\" must be an object")
            }
            for event in events where event.value.elements == nil {
                throw HookInstallerError.invalidConfig(paths.claudeSettings.path, "hook event '\(event.key)' must be an array")
            }
        }
        return (data, existed)
    }

    func run(_ operation: HookInstaller.Operation) throws -> HookInstaller.Outcome {
        let (original, existed) = try load()
        var data = original
        var outcome = HookInstaller.Outcome()
        var installSummary: [String]?
        switch operation {
        case .statusLine:
            let changed = try installStatusLine(&data)
            outcome.lines.append("status line information: " + (changed ? "enabled" : "already enabled"))
        case .uninstall:
            guard existed else { return HookInstaller.Outcome(lines: ["nothing to remove"]) }
            var removed = uninstallHooks(&data)
            let (restored, note) = try uninstallStatusLine(&data)
            if restored { removed.append("statusLine") }
            if let note { outcome.lines.append(note) }
            outcome.lines.insert("removed vibebuddy hooks from: " + (removed.isEmpty ? "(none)" : removed.joined(separator: ", ")), at: 0)
        case .install(let approval):
            let added = installHooks(&data)
            var summary = added
            if try installStatusLine(&data) { summary.append("statusLine") }
            if approval || hasApproval(data) {
                summary.append(installApproval(&data, lines: &outcome.lines))
            }
            installSummary = summary
            outcome.lines.append("Claude Code \(version?.description ?? "version unknown"): "
                + "\(Self.statusEvents(for: version).count) status events"
                + (version == nil ? " (conservative set; run install again once `claude` is on this Mac)" : ""))
        }
        outcome.changed = try writeIfChanged(data, original: original, existed: existed,
                                             to: paths.claudeSettings, agent: .claude, files: files,
                                             lines: &outcome.lines)
        if let installSummary {
            outcome.lines.insert(outcome.changed
                ? "installed vibebuddy hooks for: " + installSummary.joined(separator: ", ")
                : "vibebuddy hooks already installed (settings.json unchanged)", at: 0)
        }
        outcome.commands = Self.commands(of: data, isOurs: isOurs)
        outcome.approval = hasApproval(data)
        return outcome
    }

    func ourCommands() throws -> [String] {
        Self.commands(of: try load().0, isOurs: isOurs)
    }

    func statusLineWired() throws -> Bool { Self.isWrapper(try load().0["statusLine"]) }

    static func commands(of data: OrderedJSON, isOurs: (OrderedJSON) -> Bool) -> [String] {
        var result: [String] = []
        for member in data["hooks"]?.members ?? [] {
            for group in member.value.elements ?? [] {
                for hook in group["hooks"]?.elements ?? [] where isOurs(hook) {
                    if let command = hook["command"]?.stringValue { result.append(command) }
                }
            }
        }
        if isWrapper(data["statusLine"]), let command = data["statusLine"]?["command"]?.stringValue {
            result.append(command)
        }
        return Array(Set(result)).sorted()
    }

    // MARK: - Hooks

    /// Returns the events whose status group was (re)written.
    func installHooks(_ data: inout OrderedJSON) -> [String] {
        var hooks = data["hooks"] ?? .object([])
        var added: [String] = []
        let wanted = Self.statusEvents(for: version)
        for event in wanted {
            var groups = hooks[event]?.elements ?? []
            let expected = statusGroup(event)
            let owned = groups.filter { groupContains($0, where: isStatus) }
            if owned == [expected] { hooks[event] = .array(groups); continue }
            groups = groups.compactMap { strip($0, where: isStatus) }
            groups.append(expected)
            hooks[event] = .array(groups)
            added.append(event)
        }
        // A forwarder on an event this CLI does not know (a downgrade, or an
        // install from a newer machine) would make Claude skip the whole file.
        for event in hooks.keys where !wanted.contains(event) {
            let groups = hooks[event]?.elements ?? []
            guard groups.contains(where: { groupContains($0, where: isStatus) }) else { continue }
            let kept = groups.compactMap { strip($0, where: isStatus) }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        for event in Self.captureEvents where wanted.contains(event) {
            var groups = hooks[event]?.elements ?? []
            let owned = groups.filter { groupContains($0, where: isCapture) }
            guard owned != [captureGroup] else { continue }
            groups = groups.compactMap { strip($0, where: isCapture) }
            groups.append(captureGroup)
            hooks[event] = .array(groups)
        }
        data["hooks"] = hooks
        return added
    }

    func hasApproval(_ data: OrderedJSON) -> Bool {
        (data["hooks"]?.members ?? []).contains { member in
            (member.value.elements ?? []).contains { groupContains($0, where: isApproval) }
        }
    }

    /// The gate lives on exactly one event: PermissionRequest (fires only when
    /// Claude would ask), or PreToolUse on a CLI too old to honour a
    /// PermissionRequest decision. Retired everywhere else; the
    /// AskUserQuestion group on PreToolUse answers questions, not permissions.
    func installApproval(_ data: inout OrderedJSON, lines: inout [String]) -> String {
        var hooks = data["hooks"] ?? .object([])
        let legacy = version.map { $0 < Self.permissionRequestMinimum } ?? false
        let event = legacy ? "PreToolUse" : "PermissionRequest"
        for name in hooks.keys where name != event {
            let groups = hooks[name]?.elements ?? []
            let kept = groups.filter { !groupContains($0, where: isApproval) || isQuestionGate($0) }
            guard kept.count != groups.count else { continue }
            hooks[name] = kept.isEmpty ? nil : .array(kept)
        }
        if !legacy {
            var pre = hooks["PreToolUse"]?.elements ?? []
            let question = gateGroup(matcher: Self.questionMatcher)
            if pre.filter(isQuestionGate) != [question] {
                pre = pre.filter { !isQuestionGate($0) } + [question]
                hooks["PreToolUse"] = .array(pre)
            }
        }
        var groups = (hooks[event]?.elements ?? []).compactMap { strip($0, where: isStatus) }
        let expected = gateGroup(matcher: "*")
        if groups.filter({ groupContains($0, where: isApproval) }) != [expected] {
            groups = groups.filter { !groupContains($0, where: isApproval) } + [expected]
        }
        hooks[event] = .array(groups)
        data["hooks"] = hooks
        if legacy, let version {
            lines.append("warning: Claude Code \(version) is older than \(Self.permissionRequestMinimum); "
                + "the approval gate stays on PreToolUse, so every tool call the daemon cannot match to a "
                + "rule waits for the phone. Update Claude Code and run install again.")
        }
        return "\(event)(approval)"
    }

    /// Returns the events vibebuddy was removed from.
    func uninstallHooks(_ data: inout OrderedJSON) -> [String] {
        guard var hooks = data["hooks"] else { return [] }
        var removed: [String] = []
        for event in hooks.keys {
            let groups = hooks[event]?.elements ?? []
            guard groups.contains(where: { groupContains($0, where: isOurs) }) else { continue }
            let kept = groups.compactMap { strip($0, where: isOurs) }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
            removed.append(event)
        }
        data["hooks"] = (hooks.members ?? []).isEmpty ? nil : hooks
        return removed
    }

    // MARK: - Status line

    /// Wrap the user's status line (or add ours when there is none). The
    /// saved original is never overwritten by the wrapper itself, and a
    /// wrapper at an old path is only re-pointed, never re-wrapped.
    func installStatusLine(_ data: inout OrderedJSON) throws -> Bool {
        let existing = data["statusLine"]
        try files.ensureSupportDirectory()
        if Self.isWrapper(existing), var wrapper = existing {
            // Guard against a saved original that names the wrapper: it would
            // run itself until the machine runs out of processes.
            if let saved = files.read(paths.statusLineOriginalCommand),
               String(decoding: saved, as: UTF8.self).contains(Self.statusLineMarker) {
                try HookFileStore.atomicWrite(Data(), to: paths.statusLineOriginalCommand, permissions: 0o600)
            }
            guard wrapper["command"]?.stringValue != statusLineCommand else { return false }
            wrapper["command"] = .string(statusLineCommand)
            data["statusLine"] = wrapper
            return true
        }
        let original: OrderedJSON? = existing?.isObject == true ? existing : nil
        let saved = OrderedJSON.obj(["statusLine": original ?? .null])
        try HookFileStore.atomicWrite(saved.serialized(), to: paths.statusLineOriginal, permissions: 0o600)
        var command = ""
        if let original, (original["type"]?.stringValue ?? "command") == "command" {
            command = original["command"]?.stringValue ?? ""
        }
        if command.contains(Self.statusLineMarker) { command = "" }
        try HookFileStore.atomicWrite(Data(command.utf8), to: paths.statusLineOriginalCommand, permissions: 0o600)
        var wrapper = original ?? .object([])
        wrapper["type"] = .string("command")
        wrapper["command"] = .string(statusLineCommand)
        data["statusLine"] = wrapper
        return true
    }

    /// Put back what was there before the wrapper. Without a saved original
    /// the user's status line is never deleted: a saved command is restored
    /// on its own, and with nothing saved at all the wrapper stays (it prints
    /// nothing extra) and the report says so.
    func uninstallStatusLine(_ data: inout OrderedJSON) throws -> (Bool, String?) {
        guard Self.isWrapper(data["statusLine"]), let wrapper = data["statusLine"] else { return (false, nil) }
        var restored: OrderedJSON?? = nil   // .some(nil) = there was none
        if let bytes = files.read(paths.statusLineOriginal),
           let saved = try? OrderedJSON.parse(bytes), let value = saved["statusLine"] {
            if value.isObject { restored = .some(value) }
            else if value == .null { restored = .some(nil) }
        }
        if restored == nil, let bytes = files.read(paths.statusLineOriginalCommand) {
            let command = String(decoding: bytes, as: UTF8.self)
            if command.isEmpty {
                restored = .some(nil)
            } else if !command.contains(Self.statusLineMarker) {
                var rebuilt = wrapper
                rebuilt["command"] = .string(command)
                restored = .some(rebuilt)
            }
        }
        guard let outcome = restored else {
            return (false, "status line left in place: no saved original was found, so the vibebuddy "
                + "wrapper still runs (it adds nothing to the display). Edit statusLine in settings.json to remove it.")
        }
        data["statusLine"] = outcome
        for url in [paths.statusLineOriginal, paths.statusLineOriginalCommand] {
            try? FileManager.default.removeItem(at: url)
        }
        return (true, nil)
    }
}
