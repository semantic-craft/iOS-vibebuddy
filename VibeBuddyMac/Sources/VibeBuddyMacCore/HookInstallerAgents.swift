import Foundation

// MARK: - Codex

/// Codex CLI lifecycle hooks in `$CODEX_HOME/hooks.json` (else `~/.codex/`).
///
/// The `notify` command in `config.toml` is never touched — it may belong to
/// Codex Computer Use or another notifier — and `config.toml` is never
/// written at all; it is only read to warn when the hooks feature is off.
/// Codex runs a hook only while its recorded trust (keyed to event, matcher,
/// command, timeout and async) still covers it, so the command strings here
/// must stay identical across app updates: they name the stable `bin/` copy.
struct CodexHooks {
    let paths: HookPaths
    let context: HookInstaller.Context
    var files: HookFileStore { HookFileStore(paths: paths) }

    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
        "PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "Stop", "Interrupt", "SessionEnd",
    ]
    static let captureEvents = ["SessionStart", "UserPromptSubmit"]
    static let approvalEvent = "PermissionRequest"
    static let trustAdvice = "Codex runs changed hooks only after you trust them: start a fresh Codex session, run /hooks, and trust the VibeBuddy entries."
    static let featureDisabledAdvice = "Hooks feature disabled: run codex features enable hooks, then start a fresh Codex session."

    var forwarderCommand: String { ShellWords.quoted(paths.script("vibebuddy-forward.sh").path) + " codex" }
    var approvalCommand: String { ShellWords.quoted(paths.script("approval-hook.sh").path) + " codex" }
    var captureCommand: String { ShellWords.quoted(paths.script("capture-terminal.sh").path) }

    // Recognition: the script's basename with exactly the arguments we write,
    // wherever the script lives (app bundle, checkout, stable bin).
    private func argv(_ hook: OrderedJSON) -> [String]? {
        hook["command"]?.stringValue.flatMap(ShellWords.split)
    }
    private func matches(_ hook: OrderedJSON, script: String, arguments: [String]) -> Bool {
        guard let argv = argv(hook), argv.count == arguments.count + 1 else { return false }
        return (argv[0] as NSString).lastPathComponent == script && Array(argv.dropFirst()) == arguments
    }
    func isForwarder(_ hook: OrderedJSON) -> Bool { matches(hook, script: "vibebuddy-forward.sh", arguments: ["codex"]) }
    func isApproval(_ hook: OrderedJSON) -> Bool { matches(hook, script: "approval-hook.sh", arguments: ["codex"]) }
    func isCapture(_ hook: OrderedJSON) -> Bool { matches(hook, script: "capture-terminal.sh", arguments: []) }
    func isOurs(_ hook: OrderedJSON) -> Bool {
        isForwarder(hook) || isApproval(hook) || isCapture(hook)
            || hook["command"]?.stringValue.map(context.knownCommands.contains) == true
    }

    func load() throws -> (OrderedJSON, Bool) {
        let url = paths.codexHooks
        let (root, existed) = try loadJSONObject(url, files: files)
        guard let hooks = root["hooks"] else { return (root, existed) }
        guard let events = hooks.members else {
            throw HookInstallerError.invalidConfig(url.path, "'hooks' must be an object")
        }
        for event in events {
            guard let groups = event.value.elements else {
                throw HookInstallerError.invalidConfig(url.path, "hook event '\(event.key)' must contain an array")
            }
            for group in groups {
                guard group.isObject, let handlers = group["hooks"]?.elements else {
                    throw HookInstallerError.invalidConfig(url.path, "hook event '\(event.key)' contains an invalid group")
                }
                guard handlers.allSatisfy(\.isObject) else {
                    throw HookInstallerError.invalidConfig(url.path, "hook event '\(event.key)' contains an invalid command")
                }
            }
        }
        return (root, existed)
    }

    func hasApproval(_ root: OrderedJSON) -> Bool {
        (root["hooks"]?[Self.approvalEvent]?.elements ?? []).contains { groupContains($0, where: isApproval) }
    }

    /// Keys in sorted order, matching what the Python installer (sort_keys)
    /// left on disk; Codex's trust hash ignores key order either way.
    private func handler(_ command: String, timeout: Int, async: Bool) -> OrderedJSON {
        var members: [OrderedJSON.Member] = []
        if async { members.append(.init(key: "async", value: .bool(true))) }
        members += [.init(key: "command", value: .string(command)),
                    .init(key: "timeout", value: .int(timeout)),
                    .init(key: "type", value: .string("command"))]
        return .obj(["hooks": .array([.object(members)])])
    }

    /// Status delivery runs in the background everywhere Codex allows it;
    /// Codex forces SessionEnd back to synchronous and warns, so it is
    /// installed synchronous.
    private static func isAsync(_ event: String) -> Bool { event != "SessionEnd" }

    func install(_ root: inout OrderedJSON, approval requested: Bool) {
        let approval = requested || hasApproval(root)
        var hooks = root["hooks"] ?? .object([])
        let wanted = Set(Self.events + Self.captureEvents)
        for event in hooks.keys {
            let kept = (hooks[event]?.elements ?? []).compactMap { strip($0, where: isOurs) }
            hooks[event] = kept.isEmpty && !wanted.contains(event) ? nil : .array(kept)
        }
        func append(_ event: String, _ group: OrderedJSON) {
            hooks[event] = .array((hooks[event]?.elements ?? []) + [group])
        }
        for event in Self.events {
            if approval && event == Self.approvalEvent {
                // Synchronous: Codex applies a decision only from a hook it waited for.
                append(event, handler(approvalCommand, timeout: 30, async: false))
            } else {
                append(event, handler(forwarderCommand, timeout: 3, async: Self.isAsync(event)))
            }
        }
        for event in Self.captureEvents {
            append(event, handler(captureCommand, timeout: 5, async: Self.isAsync(event)))
        }
        root["hooks"] = hooks
    }

    func uninstall(_ root: inout OrderedJSON) {
        guard var hooks = root["hooks"] else { return }
        for event in hooks.keys {
            let kept = (hooks[event]?.elements ?? []).compactMap { strip($0, where: isOurs) }
            hooks[event] = kept.isEmpty ? nil : .array(kept)
        }
        root["hooks"] = (hooks.members ?? []).isEmpty ? nil : hooks
    }

    func run(_ operation: HookInstaller.Operation) throws -> HookInstaller.Outcome {
        let (original, existed) = try load()
        var root = original
        var outcome = HookInstaller.Outcome()
        switch operation {
        case .statusLine: return outcome
        case .uninstall:
            guard existed else { return HookInstaller.Outcome(lines: ["nothing to remove"]) }
            uninstall(&root)
            if (root.members ?? []).isEmpty, root != original {
                // Nothing but our hooks was ever in it.
                _ = try files.remove(paths.codexHooks, agent: .codex)
                return HookInstaller.Outcome(changed: true, lines: ["removed VibeBuddy Codex lifecycle hooks; removed the now-empty \(paths.codexHooks.path)"])
            }
        case .install(let approval):
            install(&root, approval: approval)
        }
        outcome.changed = try writeIfChanged(root, original: original, existed: existed, to: paths.codexHooks,
                                             agent: .codex, files: files, lines: &outcome.lines)
        if case .install(let approval) = operation {
            outcome.lines.insert(outcome.changed
                ? "installed VibeBuddy Codex lifecycle hooks; preserved all other hooks and notify"
                : "VibeBuddy Codex lifecycle hooks already in requested state — no-op", at: 0)
            if approval { outcome.lines.append("the blocking phone-approval gate is on PermissionRequest") }
            if outcome.changed { outcome.lines.append(Self.trustAdvice) }
            if Self.hooksFeatureDisabled(paths: paths) { outcome.lines.append(Self.featureDisabledAdvice) }
        } else {
            outcome.lines.insert(outcome.changed ? "removed VibeBuddy Codex lifecycle hooks" : "nothing to remove", at: 0)
        }
        outcome.commands = ourCommands(in: root)
        outcome.approval = hasApproval(root)
        return outcome
    }

    func ourCommands(in root: OrderedJSON) -> [String] {
        let all = (root["hooks"]?.members ?? []).flatMap { member in
            (member.value.elements ?? []).flatMap { group in
                (group["hooks"]?.elements ?? []).filter(isOurs).compactMap { $0["command"]?.stringValue }
            }
        }
        return Array(Set(all)).sorted()
    }

    func ourCommands() throws -> [String] { ourCommands(in: try load().0) }

    /// Read-only: the same narrow scalar scan the Settings diagnostic uses.
    static func hooksFeatureDisabled(paths: HookPaths) -> Bool {
        guard let data = HookFileStore(paths: paths).read(paths.codexConfig), data.count <= 1 << 20,
              let text = String(data: data, encoding: .utf8) else { return false }
        return ObservationHealthDetector.codexHooksFeatureDisabled(configText: text)
    }
}

// MARK: - Grok

/// Grok Build reads every `<grok home>/hooks/*.json`; vibebuddy owns
/// `vibebuddy.json` outright. Grok's `http` hooks refuse loopback, so these
/// are command hooks. A command with no argument is resolved by Grok as a
/// literal path (quotes included), so every command carries the inert `grok`
/// argument and is shell-parsed instead.
struct GrokHooks {
    let paths: HookPaths
    let context: HookInstaller.Context
    var files: HookFileStore { HookFileStore(paths: paths) }

    static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Stop", "StopFailure", "StopCancelled", "Notification", "SubagentStart", "SubagentStop", "SessionEnd",
    ]
    static let captureEvents = ["SessionStart", "UserPromptSubmit"]

    var legacyBackup: URL { paths.grokHooks.appendingPathExtension("vibebuddy-backup") }

    private func command(_ script: String) -> String {
        ShellWords.quoted(paths.script(script).path) + " grok"
    }

    private func group(_ command: String, timeout: Int = 5) -> OrderedJSON {
        .obj(["hooks": .array([.obj(["type": .string("command"), "command": .string(command),
                                     "timeout": .int(timeout)])])])
    }

    func build(approval: Bool) -> OrderedJSON {
        var hooks: [OrderedJSON.Member] = Self.events.map {
            .init(key: $0, value: .array([group(command("vibebuddy-forward.sh"))]))
        }
        var object = OrderedJSON.object(hooks)
        if approval {
            // Replaces the fire-and-forget PreToolUse update; every tool, 30 s.
            object["PreToolUse"] = .array([group(command("approval-hook.sh"), timeout: 30)])
        }
        for event in Self.captureEvents {
            object[event] = .array((object[event]?.elements ?? []) + [group(command("capture-terminal.sh"))])
        }
        hooks = object.members ?? []
        return .obj(["hooks": .object(hooks)])
    }

    private func text() -> String? { files.read(paths.grokHooks).map { String(decoding: $0, as: UTF8.self) } }

    func isOurs() -> Bool { text()?.contains("vibebuddy-forward.sh") == true }
    func hasApproval() -> Bool { isOurs() && text()?.contains("approval-hook.sh") == true }

    var statusLine: GrokStatusLine { GrokStatusLine(paths: paths) }

    func run(_ operation: HookInstaller.Operation) throws -> HookInstaller.Outcome {
        var outcome = HookInstaller.Outcome()
        let target = paths.grokHooks
        switch operation {
        case .statusLine:
            let changed = try statusLine.install(lines: &outcome.lines)
            outcome.lines.insert("status line information: " + (changed ? "enabled" : statusLine.isWired()
                ? "already enabled" : "not enabled"), at: 0)
            if changed { outcome.lines.append("applies to Grok sessions started from now on.") }
            outcome.changed = changed
            outcome.commands = try ourCommands()
            outcome.approval = hasApproval()
            return outcome
        case .install(let requested):
            let approval = requested || hasApproval()
            if !requested && approval { outcome.lines.append("keeping the existing approval gate (uninstall removes it)") }
            let payload = build(approval: approval)
            let existing = files.read(target)
            if let existing, !isOurs(), !files.exists(legacyBackup) {
                // Someone else's file under our name: set it aside once, restore on uninstall.
                try HookFileStore.atomicWrite(existing, to: legacyBackup, permissions: 0o600)
                outcome.lines.append("backup written: \(legacyBackup.path)")
            }
            let current = existing.flatMap { try? OrderedJSON.parse($0) }
            if current != payload {
                if let backup = try files.write(payload.serialized(), to: target, agent: .grok, permissions: 0o644) {
                    outcome.lines.append("backup: \(backup.path)")
                }
                outcome.changed = true
            }
            if try statusLine.install(lines: &outcome.lines) {
                outcome.changed = true
                outcome.lines.append("status line information enabled in \(paths.grokConfig.path) (new sessions).")
            }
            outcome.lines.insert("\(outcome.changed ? "installed" : "already installed:") vibebuddy grok hooks"
                + (approval ? " + approval gate" : "") + ": \(target.path)", at: 0)
            if approval {
                outcome.lines.append("phone answers are authoritative only with [ui] permission_mode = \"always-approve\" in the Grok config.toml.")
            }
            outcome.lines.append("reload in grok: /hooks → 'r', or start a new session.")
            outcome.approval = approval
            outcome.commands = try ourCommands()
        case .uninstall:
            if try statusLine.uninstall(lines: &outcome.lines) {
                outcome.changed = true
                outcome.lines.append("status line restored: \(paths.grokConfig.path)")
            }
            guard files.exists(target), isOurs() else {
                if !outcome.changed { outcome.lines.append("nothing to remove (not installed by vibebuddy)") }
                return outcome
            }
            _ = try files.remove(target, agent: .grok)
            outcome.changed = true
            outcome.lines.append("removed: \(target.path)")
            if files.exists(legacyBackup) {
                try FileManager.default.moveItem(at: legacyBackup, to: target)
                outcome.lines.append("restored backup: \(target.path)")
            }
            removeIfEmpty(target.deletingLastPathComponent())
        }
        return outcome
    }

    /// The hook commands, plus the status line wrapper when it is wired.
    func ourCommands() throws -> [String] {
        var all = statusLine.ourCommand().map { [$0] } ?? []
        if isOurs(), let data = files.read(paths.grokHooks), let root = try? OrderedJSON.parse(data) {
            all += (root["hooks"]?.members ?? []).flatMap { member in
                (member.value.elements ?? []).flatMap(commands(in:))
            }
        }
        return Array(Set(all)).sorted()
    }
}

// MARK: - Cursor

/// Cursor (IDE and `cursor-agent`) reads one user-level file,
/// `$CURSOR_HOME/hooks.json` (else `~/.cursor/`), shaped
/// `{"version": 1, "hooks": {"<event>": [{"command": …, "timeout": …}]}}`.
/// It is shared with the user's own hooks, so this only ever adds, replaces
/// or removes entries whose command is one of vibebuddy's scripts; foreign
/// entries stay in place and in order, options included. `preToolUse` is the
/// single place for the blocking gate (it fires for every tool, shell and MCP
/// included); `stop` runs the follow-up collector with `loop_limit: null`, so
/// Cursor does not cap queued phone messages at five.
struct CursorHooks {
    let paths: HookPaths
    let context: HookInstaller.Context
    var files: HookFileStore { HookFileStore(paths: paths) }

    static let statusEvents = [
        "sessionStart", "sessionEnd", "beforeSubmitPrompt",
        "postToolUse", "postToolUseFailure", "afterFileEdit",
        "afterAgentResponse", "afterAgentThought", "preCompact",
        "subagentStart", "subagentStop",
    ]
    static let markers = ["vibebuddy-forward.sh", "approval-hook.sh", "capture-terminal.sh", "cursor-followup.sh"]

    private func quoted(_ script: String) -> String { ShellWords.quoted(paths.script(script).path) }

    private func entry(_ command: String, timeout: Int = 5, loopLimitNull: Bool = false) -> OrderedJSON {
        var members: [OrderedJSON.Member] = [.init(key: "command", value: .string(command)),
                                             .init(key: "timeout", value: .int(timeout))]
        if loopLimitNull { members.append(.init(key: "loop_limit", value: .null)) }
        return .object(members)
    }

    /// The entries vibebuddy wants, per event, in order.
    func desired(approval: Bool) -> [(String, [OrderedJSON])] {
        let forward = quoted("vibebuddy-forward.sh") + " cursor"
        var result: [(String, [OrderedJSON])] = Self.statusEvents.map { ($0, [entry(forward)]) }
        result[0].1.append(entry(quoted("capture-terminal.sh") + " cursor", timeout: 10))
        result.append(("preToolUse", [approval ? entry(quoted("approval-hook.sh") + " cursor", timeout: 30) : entry(forward)]))
        result.append(("stop", [entry(quoted("cursor-followup.sh"), timeout: 5, loopLimitNull: true)]))
        return result
    }

    func isOurs(_ item: OrderedJSON) -> Bool {
        guard let command = item["command"]?.stringValue else { return false }
        return Self.markers.contains(where: command.contains) || context.knownCommands.contains(command)
    }

    /// The document with `version` and `hooks` guaranteed, plus the bytes-on-disk
    /// value it came from (so adding a missing `version` counts as a change).
    func load() throws -> (OrderedJSON, raw: OrderedJSON, existed: Bool) {
        let (document, existed) = try loadJSONObject(paths.cursorHooks, files: files)
        var doc = document
        if doc["version"] == nil {
            doc = .object([.init(key: "version", value: .int(1))] + (doc.members ?? []))
        }
        if let hooks = doc["hooks"] {
            guard let events = hooks.members else {
                throw HookInstallerError.invalidConfig(paths.cursorHooks.path, "\"hooks\" must be an object")
            }
            for event in events where event.value.elements == nil {
                throw HookInstallerError.invalidConfig(paths.cursorHooks.path, "hook event '\(event.key)' must be an array")
            }
        } else {
            doc["hooks"] = .object([])
        }
        return (doc, document, existed)
    }

    func hasApproval(_ document: OrderedJSON) -> Bool {
        (document["hooks"]?.members ?? []).contains { member in
            (member.value.elements ?? []).contains { isOurs($0) && ($0["command"]?.stringValue ?? "").contains("approval-hook.sh") }
        }
    }

    func merge(_ document: inout OrderedJSON, approval: Bool) {
        var hooks = document["hooks"] ?? .object([])
        let wanted = desired(approval: approval)
        let wantedEvents = Set(wanted.map(\.0))
        for event in hooks.keys {
            guard let items = hooks[event]?.elements else { continue }
            let kept = items.filter { !isOurs($0) }
            hooks[event] = kept.isEmpty && !wantedEvents.contains(event) ? nil : .array(kept)
        }
        for (event, items) in wanted {
            hooks[event] = .array(items + (hooks[event]?.elements ?? []))
        }
        document["hooks"] = hooks
    }

    func run(_ operation: HookInstaller.Operation) throws -> HookInstaller.Outcome {
        var outcome = HookInstaller.Outcome()
        switch operation {
        case .statusLine: return outcome
        case .install(let requested):
            // An unreadable file (a comment, a trailing comma) is refused like
            // Claude's and Codex's, never replaced: it holds the user's hooks.
            let (loaded, raw, existed) = try load()
            var document = loaded
            let original = document
            let approval = requested || hasApproval(original)
            if !requested && approval { outcome.lines.append("keeping the existing approval gate (uninstall removes it)") }
            merge(&document, approval: approval)
            outcome.changed = try writeIfChanged(document, original: raw, existed: existed,
                                                 to: paths.cursorHooks, agent: .cursor, files: files, lines: &outcome.lines)
            outcome.lines.insert("\(outcome.changed ? "installed" : "already installed:") vibebuddy Cursor hooks"
                + (approval ? " + approval gate" : "") + ": \(paths.cursorHooks.path)", at: 0)
            if outcome.changed {
                outcome.lines.append("Cursor watches hooks.json and reloads on save; restart Cursor if it does not pick it up.")
            }
            if let claude = files.read(paths.claudeSettings), String(decoding: claude, as: UTF8.self).contains("vibebuddy") {
                outcome.lines.append("note: Claude Code's settings.json also carries vibebuddy hooks; if Cursor's third-party hooks are enabled, Cursor calls them too — vibebuddy recognises the Cursor payload and keeps one session identity.")
            }
            outcome.approval = approval
            outcome.commands = ourCommands(in: document)
        case .uninstall:
            guard files.exists(paths.cursorHooks) else { return HookInstaller.Outcome(lines: ["nothing to remove"]) }
            let (original, raw, _) = try load()
            var document = original
            var hooks = document["hooks"] ?? .object([])
            var removed = 0
            for event in hooks.keys {
                guard let items = hooks[event]?.elements else { continue }
                let kept = items.filter { !isOurs($0) }
                removed += items.count - kept.count
                hooks[event] = kept.isEmpty ? nil : .array(kept)
            }
            guard removed > 0 else { return HookInstaller.Outcome(lines: ["nothing to remove (not installed by vibebuddy)"]) }
            document["hooks"] = hooks
            outcome.changed = true
            let onlyShell = (hooks.members ?? []).isEmpty && Set(document.keys).isSubset(of: ["version", "hooks"])
            if onlyShell {
                _ = try files.remove(paths.cursorHooks, agent: .cursor)
                outcome.lines.append("removed: \(paths.cursorHooks.path)")
            } else {
                _ = try writeIfChanged(document, original: raw, existed: true, to: paths.cursorHooks,
                                       agent: .cursor, files: files, lines: &outcome.lines)
                outcome.lines.insert("removed \(removed) vibebuddy hook entries, kept your own: \(paths.cursorHooks.path)", at: 0)
            }
        }
        return outcome
    }

    func ourCommands(in document: OrderedJSON) -> [String] {
        let all = (document["hooks"]?.members ?? []).flatMap { member in
            (member.value.elements ?? []).filter(isOurs).compactMap { $0["command"]?.stringValue }
        }
        return Array(Set(all)).sorted()
    }

    func ourCommands() throws -> [String] {
        guard files.exists(paths.cursorHooks) else { return [] }
        return ourCommands(in: try load().0)
    }
}

// MARK: - OpenCode

/// OpenCode auto-loads JS plugins from `$XDG_CONFIG_HOME/opencode/plugins/`
/// (else `~/.config/opencode/plugins/`). The plugin is copied there from the
/// stable `bin/` copy; it is ours when it is byte-identical or carries the
/// plugin's own header (an older vibebuddy version).
struct OpenCodePlugin {
    let paths: HookPaths
    let context: HookInstaller.Context
    var files: HookFileStore { HookFileStore(paths: paths) }

    var target: URL { paths.opencodePlugin }
    var legacyBackup: URL { target.appendingPathExtension("vibebuddy-backup") }

    func isOurs(_ data: Data?) -> Bool {
        guard let data else { return false }
        if data == files.read(paths.script(HookInstaller.opencodePlugin)) { return true }
        let text = String(decoding: data, as: UTF8.self)
        return text.contains("VibeBuddy OpenCode plugin") || text.contains("/hook?agent=opencode")
    }

    func run(_ operation: HookInstaller.Operation) throws -> HookInstaller.Outcome {
        var outcome = HookInstaller.Outcome()
        let existing = files.read(target)
        switch operation {
        case .statusLine: return outcome
        case .install:
            guard let source = files.read(paths.script(HookInstaller.opencodePlugin)) else {
                throw HookInstallerError.scriptsMissing(paths.script(HookInstaller.opencodePlugin).path)
            }
            outcome.commands = [target.path]
            if existing == source {
                outcome.lines.append("opencode plugin already installed (identical): \(target.path)")
                return outcome
            }
            if let existing, !isOurs(existing), !files.exists(legacyBackup) {
                try HookFileStore.atomicWrite(existing, to: legacyBackup, permissions: 0o644)
                outcome.lines.append("backup written: \(legacyBackup.path)")
            }
            if let backup = try files.write(source, to: target, agent: .opencode, permissions: 0o644) {
                outcome.lines.append("backup: \(backup.path)")
            }
            outcome.changed = true
            outcome.lines.insert("installed opencode plugin: \(target.path)", at: 0)
        case .uninstall:
            guard isOurs(existing) else {
                return HookInstaller.Outcome(lines: ["nothing to remove (not the vibebuddy plugin)"])
            }
            _ = try files.remove(target, agent: .opencode)
            outcome.changed = true
            if files.exists(legacyBackup) {
                try FileManager.default.moveItem(at: legacyBackup, to: target)
                outcome.lines.append("restored backup: \(target.path)")
            } else {
                outcome.lines.append("removed opencode plugin: \(target.path)")
                removeIfEmpty(target.deletingLastPathComponent())
            }
        }
        return outcome
    }

    func ourCommands() throws -> [String] { isOurs(files.read(target)) ? [target.path] : [] }
}

// MARK: - Antigravity

/// Antigravity (`agy`) loads `~/.gemini/antigravity-cli/hooks.json`, keyed by
/// hook *name*; vibebuddy manages the single `vibebuddy` spec. agy 1.0.5
/// loads but does not yet execute hooks (an agy-side bug); the wiring is
/// ready for when it does.
struct AntigravityHooks {
    let paths: HookPaths
    let context: HookInstaller.Context
    var files: HookFileStore { HookFileStore(paths: paths) }

    static let hookName = "vibebuddy"
    static let events = ["PreToolUse", "PostToolUse", "PreInvocation", "Stop"]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]

    func spec() -> OrderedJSON {
        let handler = OrderedJSON.obj([
            "type": .string("command"),
            "command": .string(ShellWords.quoted(paths.script("vibebuddy-forward.sh").path) + " antigravity"),
            "timeout": .int(5)])
        return .object(Self.events.map { event in
            // Tool events nest handlers under a matcher; the rest take them directly.
            .init(key: event, value: Self.toolEvents.contains(event)
                  ? .array([.obj(["matcher": .string(""), "hooks": .array([handler])])])
                  : .array([handler]))
        })
    }

    func run(_ operation: HookInstaller.Operation) throws -> HookInstaller.Outcome {
        let (original, existed) = try loadJSONObject(paths.antigravityHooks, files: files)
        var hooks = original
        var outcome = HookInstaller.Outcome()
        switch operation {
        case .statusLine: return outcome
        case .install:
            hooks[Self.hookName] = spec()
            outcome.changed = try writeIfChanged(hooks, original: original, existed: existed,
                                                 to: paths.antigravityHooks, agent: .antigravity,
                                                 files: files, lines: &outcome.lines)
            outcome.lines.insert(outcome.changed ? "installed vibebuddy antigravity hook for events: "
                                 + Self.events.joined(separator: ", ") : "antigravity hook already installed", at: 0)
            outcome.lines.append("note: agy 1.0.5 loads but does not execute hooks; the wiring is ready for when it does.")
            outcome.commands = try ourCommands()
        case .uninstall:
            guard existed, hooks[Self.hookName] != nil else {
                return HookInstaller.Outcome(lines: ["removed vibebuddy antigravity hook: (none)"])
            }
            hooks[Self.hookName] = nil
            outcome.changed = true
            if (hooks.members ?? []).isEmpty {
                _ = try files.remove(paths.antigravityHooks, agent: .antigravity)
            } else {
                _ = try writeIfChanged(hooks, original: original, existed: true, to: paths.antigravityHooks,
                                       agent: .antigravity, files: files, lines: &outcome.lines)
            }
            outcome.lines.insert("removed vibebuddy antigravity hook: yes", at: 0)
        }
        return outcome
    }

    func ourCommands() throws -> [String] {
        guard let data = files.read(paths.antigravityHooks), let root = try? OrderedJSON.parse(data),
              let spec = root[Self.hookName] else { return [] }
        var all: [String] = []
        for member in spec.members ?? [] {
            for item in member.value.elements ?? [] {
                if let command = item["command"]?.stringValue { all.append(command) }
                all += commands(in: item)
            }
        }
        return Array(Set(all)).sorted()
    }
}

/// Drop a directory the installer may have created once nothing is left in it.
func removeIfEmpty(_ directory: URL) {
    let fm = FileManager.default
    if let contents = try? fm.contentsOfDirectory(atPath: directory.path), contents.isEmpty {
        try? fm.removeItem(at: directory)
    }
}
