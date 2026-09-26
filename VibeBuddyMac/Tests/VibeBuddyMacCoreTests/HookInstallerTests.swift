import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The native hook installer. The first suite is the port of the retired
/// `hooks/test_install_agent_hooks.py` (its behaviour spec); the rest cover
/// the eight requirements in hook-installer ticket 01, shipped in PR #266.
/// Every test runs against a throwaway home; nothing touches the real one.
@Suite("HookInstaller")
struct HookInstallerTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let modern = ClaudeCodeVersion(2, 1, 261)

    struct Home {
        let root: URL
        var variables: [String: String] = [:]
        var version: ClaudeCodeVersion? = HookInstallerTests.modern
        var source: URL? = HookInstallerTests.repo.appendingPathComponent("hooks")
        var now = Date(timeIntervalSince1970: 1_790_000_000)

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vb-hooks-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var installer: HookInstaller {
            let version = version
            let now = now
            return HookInstaller(environment: HookInstallerEnvironment(
                home: root, variables: variables, claudeVersion: { version }, now: { now }),
                scriptSource: source)
        }
        var paths: HookPaths { installer.paths }

        func url(_ relative: String) -> URL { root.appendingPathComponent(relative) }
        func write(_ relative: String, _ text: String) throws {
            let target = url(relative)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: target)
        }
        func mkdir(_ relative: String) throws {
            try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
        }
        func bytes(_ relative: String) -> Data? { FileManager.default.contents(atPath: url(relative).path) }
        func json(_ relative: String) throws -> [String: Any] {
            let data = try #require(bytes(relative))
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: helpers over decoded JSON

    static func groups(_ doc: [String: Any], _ event: String) -> [[String: Any]] {
        (doc["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }
    static func handlers(_ doc: [String: Any], _ event: String, matcher: String? = nil,
                         excludingMatcher: String? = nil) -> [[String: Any]] {
        groups(doc, event).filter { group in
            (matcher == nil || group["matcher"] as? String == matcher)
                && (excludingMatcher == nil || group["matcher"] as? String != excludingMatcher)
        }.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
    }
    static func commands(_ doc: [String: Any], _ event: String, excludingMatcher: String? = nil) -> [String] {
        handlers(doc, event, excludingMatcher: excludingMatcher).compactMap { $0["command"] as? String }
    }
    static func cursorEntries(_ doc: [String: Any], _ event: String) -> [[String: Any]] {
        groups(doc, event)
    }

    static let managed = [
        ".claude/settings.json", ".codex/config.toml", ".codex/hooks.json", ".grok/hooks/vibebuddy.json",
        ".gemini/antigravity-cli/hooks.json", ".config/opencode/plugins/vibebuddy.js", ".cursor/hooks.json",
    ]
    static let userClaudeHook = "echo i-am-a-user-hook"
    static let userCodexNotify = #"notify = ["/Applications/Existing Notifier.app/Contents/MacOS/notifier", "turn-ended"]"#
    static let userCodexHook = "echo i-am-a-user-codex-hook"
    static let userCursorHook = "./hooks/my-own-audit.sh"
    static let cursorEvents = ["sessionStart", "sessionEnd", "beforeSubmitPrompt", "postToolUse",
                               "postToolUseFailure", "afterFileEdit", "afterAgentResponse",
                               "afterAgentThought", "preCompact", "subagentStart", "subagentStop"]

    func seed(_ home: Home) throws {
        try home.write(".claude/settings.json",
            #"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\#(Self.userClaudeHook)"}]}]}}"# + "\n")
        try home.write(".codex/config.toml", "model = \"gpt-test\"\n\(Self.userCodexNotify)\n\n[features]\nexample = true\n")
        try home.write(".codex/hooks.json",
            #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"\#(Self.userCodexHook)"}]}]}}"# + "\n")
        try home.write(".qwen/settings.json", "{}\n")
        try home.write(".kimi-code/config.toml", "default_model = \"x\"\n\n[[hooks]]\nevent = \"Stop\"\n")
        try home.mkdir(".grok")
        try home.mkdir(".gemini/antigravity-cli")
        try home.mkdir(".config/opencode")
        try home.write(".cursor/hooks.json",
            #"{"version":1,"hooks":{"beforeShellExecution":[{"command":"\#(Self.userCursorHook)","failClosed":true}]}}"# + "\n")
    }

    // MARK: - Port of test_install_agent_hooks.py

    @Test("install everything twice (byte-identical), approval, repair, uninstall: user content survives")
    func universalInstaller() throws {
        let home = try Home()
        defer { home.remove() }
        try seed(home)
        let retired = [".qwen/settings.json", ".kimi-code/config.toml"].map { ($0, home.bytes($0)) }

        let first = home.installer.install()
        #expect(first.failures == 0, "\(first.text)")
        let snapshot = Self.managed.map { home.bytes($0) }
        #expect(home.installer.install().failures == 0)
        for (index, path) in Self.managed.enumerated() {
            #expect(snapshot[index] != nil, "managed file never written: \(path)")
            #expect(snapshot[index] == home.bytes(path), "not idempotent: \(path)")
        }
        for (path, original) in retired { #expect(home.bytes(path) == original, "changed \(path)") }

        // Claude
        let claude = try home.json(".claude/settings.json")
        #expect(Self.commands(claude, "PreToolUse").contains(Self.userClaudeHook))
        let permission = Self.handlers(claude, "PermissionRequest").filter {
            ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") }
        #expect(permission.first?["async"] as? Bool == true)
        // PostToolBatch is gated at 2.1.270 (the oldest release verified to
        // know it), so the 2.1.261 pinned here does not get it.
        for event in ["PostToolUseFailure", "PermissionDenied", "SubagentStart", "SubagentStop",
                      "PreCompact", "PostCompact", "StopFailure", "Elicitation", "ElicitationResult",
                      "TaskCreated", "TaskCompleted", "PostModelSwitch", "CwdChanged", "TeammateIdle"] {
            let ours = Self.handlers(claude, event).filter { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") }
            #expect(ours.first?["async"] as? Bool == true, "Claude \(event)")
        }
        for event in ["WorktreeCreate", "WorktreeRemove", "DirectoryAdded"] {
            #expect(Self.groups(claude, event).isEmpty, "Claude \(event) must not carry a hook")
        }

        // Codex
        let codexToml = try #require(home.bytes(".codex/config.toml"))
        #expect(String(decoding: codexToml, as: UTF8.self).contains(Self.userCodexNotify))
        let codex = try home.json(".codex/hooks.json")
        for event in CodexHooks.events {
            let ours = Self.handlers(codex, event).filter { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh\" codex") }
            #expect(!ours.isEmpty, "codex \(event)")
            #expect((ours.first?["async"] as? Bool ?? false) == (event != "SessionEnd"), "codex \(event) async")
            #expect((ours.first?["timeout"] as? Int ?? 99) <= 3)
        }
        #expect(Self.commands(codex, "SessionStart").contains(Self.userCodexHook))

        // Grok
        let grok = try home.json(".grok/hooks/vibebuddy.json")
        for event in GrokHooks.events {
            #expect(Self.commands(grok, event).contains { $0.contains("vibebuddy-forward.sh\" grok") }, "grok \(event)")
        }
        for event in ["SessionStart", "UserPromptSubmit"] {
            let capture = Self.commands(grok, event).filter { $0.contains("capture-terminal.sh") }
            #expect(capture.count == 1)
            #expect(capture.first?.hasSuffix("\"") == false, "grok capture must carry an argument")
        }
        #expect(!Self.commands(grok, "PreToolUse").contains { $0.contains("approval-hook.sh") })

        // Cursor
        let cursor = try home.json(".cursor/hooks.json")
        #expect(cursor["version"] as? Int == 1)
        for event in Self.cursorEvents {
            #expect(Self.cursorEntries(cursor, event).contains { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh\" cursor") }, "cursor \(event)")
        }
        let followups = Self.cursorEntries(cursor, "stop").filter { ($0["command"] as? String ?? "").contains("cursor-followup.sh") }
        #expect(!followups.isEmpty)
        #expect(followups.allSatisfy { $0.keys.contains("loop_limit") && $0["loop_limit"] is NSNull })
        #expect(Self.cursorEntries(cursor, "sessionStart").contains { ($0["command"] as? String ?? "").contains("capture-terminal.sh") })
        #expect(Self.cursorEntries(cursor, "beforeShellExecution").contains {
            $0["command"] as? String == Self.userCursorHook && $0["failClosed"] as? Bool == true })
        #expect(!(cursor["hooks"] as? [String: [[String: Any]]] ?? [:]).values.joined().contains {
            ($0["command"] as? String ?? "").contains("approval-hook.sh") })

        // --approval
        #expect(home.installer.install(approval: true).failures == 0)
        let grokGate = Self.handlers(try home.json(".grok/hooks/vibebuddy.json"), "PreToolUse")
        #expect(grokGate.contains { ($0["command"] as? String ?? "").contains("approval-hook.sh") })
        #expect(!grokGate.contains { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") })
        #expect(grokGate.allSatisfy { $0["timeout"] as? Int == 30 })
        #expect(grokGate.contains { ($0["command"] as? String ?? "").hasSuffix("\" grok") })
        let claudeApproved = try home.json(".claude/settings.json")
        let claudeGate = Self.handlers(claudeApproved, "PermissionRequest")
        // The Claude gate asks for the away hold and gives its hook room above it (WR-11).
        #expect(claudeGate.contains { ($0["command"] as? String ?? "").hasSuffix("approval-hook.sh\" claude 60")
            && $0["timeout"] as? Int == 75 })
        #expect(!claudeGate.contains { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") })
        let claudePre = Self.handlers(claudeApproved, "PreToolUse", excludingMatcher: "AskUserQuestion")
        #expect(!claudePre.contains { ($0["command"] as? String ?? "").contains("approval-hook.sh") })
        #expect(claudePre.contains { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") && $0["async"] as? Bool == true })
        #expect(Self.handlers(claudeApproved, "PreToolUse", matcher: "AskUserQuestion").contains {
            ($0["command"] as? String ?? "").hasSuffix("approval-hook.sh\" claude 60") && $0["timeout"] as? Int == 75 })
        let codexApproved = try home.json(".codex/hooks.json")
        let codexGate = Self.handlers(codexApproved, "PermissionRequest")
        #expect(codexGate.contains { ($0["command"] as? String ?? "").hasSuffix("approval-hook.sh\" codex") && $0["timeout"] as? Int == 30 })
        #expect(!codexGate.contains { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") })
        #expect(codexGate.allSatisfy { $0["async"] == nil })
        #expect(Self.commands(codexApproved, "PreToolUse").contains { $0.contains("vibebuddy-forward.sh\" codex") })
        #expect(!Self.commands(codexApproved, "PreToolUse").contains { $0.contains("approval-hook.sh") })
        #expect(Self.commands(codexApproved, "SessionStart").contains(Self.userCodexHook))
        let cursorApproved = try home.json(".cursor/hooks.json")
        let cursorGate = Self.cursorEntries(cursorApproved, "preToolUse")
        #expect(cursorGate.contains { ($0["command"] as? String ?? "").hasSuffix("approval-hook.sh\" cursor") && $0["timeout"] as? Int == 30 })
        #expect(!cursorGate.contains { ($0["command"] as? String ?? "").contains("vibebuddy-forward.sh") })
        #expect(!Self.cursorEntries(cursorApproved, "beforeShellExecution").contains {
            ($0["command"] as? String ?? "").contains("approval-hook.sh") })

        // A plain re-install (Repair) keeps every gate.
        #expect(home.installer.install().failures == 0)
        #expect(Self.commands(try home.json(".grok/hooks/vibebuddy.json"), "PreToolUse").contains { $0.contains("approval-hook.sh") })
        let claudeKept = Self.commands(try home.json(".claude/settings.json"), "PermissionRequest")
        #expect(claudeKept.contains { $0.contains("approval-hook.sh") })
        #expect(!claudeKept.contains { $0.contains("vibebuddy-forward.sh") })
        #expect(Self.cursorEntries(try home.json(".cursor/hooks.json"), "preToolUse").contains {
            ($0["command"] as? String ?? "").contains("approval-hook.sh") })
        let codexKept = Self.commands(try home.json(".codex/hooks.json"), "PermissionRequest")
        #expect(codexKept.contains { $0.contains("approval-hook.sh") })
        #expect(!codexKept.contains { $0.contains("vibebuddy-forward.sh") })

        // Claude capture carries an inert argument (Grok's compat bridge).
        let captures = ["SessionStart", "UserPromptSubmit"].flatMap {
            Self.commands(try! home.json(".claude/settings.json"), $0).filter { $0.contains("capture-terminal.sh") } }
        #expect(captures.count == 2)
        #expect(captures.allSatisfy { !$0.hasSuffix("\"") })

        // Uninstall: clean, user content preserved.
        #expect(home.installer.uninstall().failures == 0)
        for (path, original) in retired { #expect(home.bytes(path) == original) }
        let claudeAfter = String(decoding: try #require(home.bytes(".claude/settings.json")), as: UTF8.self)
        for marker in ["vibebuddy-forward.sh", "capture-terminal.sh", "approval-hook.sh", "9876/hook", "statusline"] {
            #expect(!claudeAfter.contains(marker), "claude kept \(marker)")
        }
        #expect(claudeAfter.contains(Self.userClaudeHook))
        #expect(home.bytes(".codex/config.toml") == codexToml)
        let codexAfter = try home.json(".codex/hooks.json")
        let codexLeft = (codexAfter["hooks"] as? [String: Any] ?? [:]).keys.flatMap { Self.commands(codexAfter, $0) }
        #expect(codexLeft == [Self.userCodexHook])
        #expect(!home.exists(".grok/hooks/vibebuddy.json"))
        #expect(!home.exists(".config/opencode/plugins/vibebuddy.js"))
        #expect(!home.exists(".gemini/antigravity-cli/hooks.json"))
        let cursorAfter = try home.json(".cursor/hooks.json")
        #expect(cursorAfter["version"] as? Int == 1)
        let cursorLeft = (cursorAfter["hooks"] as? [String: [[String: Any]]] ?? [:]).values.joined()
        #expect(cursorLeft.count == 1)
        #expect(cursorLeft.first?["command"] as? String == Self.userCursorHook && cursorLeft.first?["failClosed"] as? Bool == true)
    }

    @Test("Codex hooks-feature diagnostic warns on install only and never rewrites config.toml")
    func codexFeatureDiagnostic() throws {
        struct Fixture: Decodable { let name: String; let config: String; let disabled: Bool }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
            Self.repo.appendingPathComponent("hooks/fixtures/codex-hooks-feature.json")))
        for fixture in fixtures {
            let home = try Home()
            defer { home.remove() }
            try home.write(".codex/config.toml", fixture.config)
            let original = home.bytes(".codex/config.toml")
            for approval in [false, true] {
                let report = home.installer.install([.codex], approval: approval)
                #expect(report.text.contains("codex features enable hooks") == fixture.disabled, "\(fixture.name)")
                #expect(home.bytes(".codex/config.toml") == original)
            }
            let removed = home.installer.uninstall([.codex])
            #expect(!removed.text.contains("codex features enable hooks"))
            #expect(home.bytes(".codex/config.toml") == original)
        }
    }

    @Test("GROK_HOME redirects install and uninstall")
    func grokHome() throws {
        var home = try Home()
        defer { home.remove() }
        home.variables["GROK_HOME"] = home.url("elsewhere/grok").path
        #expect(home.installer.install([.grok]).failures == 0)
        let target = "elsewhere/grok/hooks/vibebuddy.json"
        #expect(home.exists(target))
        #expect(!home.exists(".grok/hooks/vibebuddy.json"))
        let hooks = try home.json(target)
        for event in GrokHooks.events {
            #expect(Self.commands(hooks, event).contains { $0.contains("vibebuddy-forward.sh\" grok") })
        }
        #expect(home.installer.uninstall([.grok]).failures == 0)
        #expect(!home.exists(target))
    }

    @Test("the status-line-only action never edits hooks; idempotent; original saved")
    func statusLineOnly() throws {
        let home = try Home()
        defer { home.remove() }
        let original = #"{"hooks":{"PermissionRequest":[{"hooks":[{"command":"user gate"}]}]},"statusLine":{"type":"command","command":"echo existing","padding":2}}"#
        try home.write(".claude/settings.json", original)
        var previous: Data?
        for _ in 0..<2 {
            #expect(home.installer.enableStatusLine().failures == 0)
            let current = try #require(home.bytes(".claude/settings.json"))
            let doc = try home.json(".claude/settings.json")
            #expect(Self.commands(doc, "PermissionRequest") == ["user gate"])
            #expect((doc["hooks"] as? [String: Any])?.count == 1)
            if let previous { #expect(previous == current) }
            previous = current
            let savedData = try #require(FileManager.default.contents(atPath: home.paths.statusLineOriginal.path))
            let saved = try #require(JSONSerialization.jsonObject(with: savedData) as? [String: Any])
            #expect((saved["statusLine"] as? [String: Any])?["command"] as? String == "echo existing")
            #expect((saved["statusLine"] as? [String: Any])?["padding"] as? Int == 2)
        }
    }

    @Test("install wraps the status line keeping its fields; uninstall restores it exactly")
    func statusLineWrapper() throws {
        let home = try Home()
        defer { home.remove() }
        let original = #"{"statusLine":{"type":"command","command":"~/.claude/statusline.sh","padding":1}}"#
        try home.write(".claude/settings.json", original)
        #expect(home.installer.install([.claude]).failures == 0)
        let line = try #require(try home.json(".claude/settings.json")["statusLine"] as? [String: Any])
        #expect((line["command"] as? String)?.contains(home.paths.script("vibebuddy-statusline.sh").path) == true)
        #expect(line["padding"] as? Int == 1)
        let cmd = home.paths.statusLineOriginalCommand.path
        #expect(FileManager.default.contents(atPath: cmd) == Data("~/.claude/statusline.sh".utf8))
        _ = home.installer.install([.claude])
        #expect(FileManager.default.contents(atPath: cmd) == Data("~/.claude/statusline.sh".utf8))
        #expect(home.installer.uninstall([.claude]).failures == 0)
        let restored = try #require(try home.json(".claude/settings.json")["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "~/.claude/statusline.sh" && restored["padding"] as? Int == 1)
        #expect(restored.count == 3)
        #expect(!FileManager.default.fileExists(atPath: cmd))

        // No original: install adds the wrapper alone, uninstall removes the key.
        try home.write(".claude/settings.json", "{}")
        _ = home.installer.install([.claude])
        #expect((try home.json(".claude/settings.json")["statusLine"] as? [String: Any]) != nil)
        #expect(FileManager.default.contents(atPath: cmd) == Data())
        _ = home.installer.uninstall([.claude])
        #expect(try home.json(".claude/settings.json")["statusLine"] == nil)
    }

    @Test("an old Claude Code keeps the legacy gate on PreToolUse and says so; an update migrates it")
    func oldCliKeepsLegacyGate() throws {
        var home = try Home()
        defer { home.remove() }
        home.version = ClaudeCodeVersion(parsing: "2.1.200 (Claude Code)")
        let report = home.installer.install([.claude], approval: true)
        #expect(report.failures == 0)
        var doc = try home.json(".claude/settings.json")
        #expect(Self.commands(doc, "PreToolUse", excludingMatcher: "AskUserQuestion").contains { $0.contains("approval-hook.sh") })
        #expect(!Self.commands(doc, "PermissionRequest").contains { $0.contains("approval-hook.sh") })
        #expect(report.text.contains("older than 2.1.257"))
        home.version = ClaudeCodeVersion(2, 1, 261)
        let updated = home.installer.install([.claude])
        doc = try home.json(".claude/settings.json")
        #expect(!Self.commands(doc, "PreToolUse", excludingMatcher: "AskUserQuestion").contains { $0.contains("approval-hook.sh") })
        #expect(Self.commands(doc, "PermissionRequest").contains { $0.contains("approval-hook.sh") })
        #expect(!updated.text.contains("older than"))
    }

    @Test("a pre-PermissionRequest gate on PreToolUse is migrated by a plain install")
    func legacyGateMigration() throws {
        let home = try Home()
        defer { home.remove() }
        let gate = Self.repo.appendingPathComponent("hooks/approval-hook.sh").path
        try home.write(".claude/settings.json",
            #"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\"\#(gate)\""}]}]}}"#)
        #expect(home.installer.install([.claude]).failures == 0)
        let doc = try home.json(".claude/settings.json")
        let pre = Self.commands(doc, "PreToolUse", excludingMatcher: "AskUserQuestion")
        #expect(!pre.contains { $0.contains("approval-hook.sh") })
        #expect(pre.contains { $0.contains("vibebuddy-forward.sh") })
        #expect(Self.commands(doc, "PermissionRequest").contains { $0.contains("approval-hook.sh") })
    }

    // MARK: - Requirement 1: stable hook path

    @Test("configs name only the stable bin copy, which install verifies and launch refreshes")
    func stablePath() throws {
        let home = try Home()
        defer { home.remove() }
        try seed(home)
        #expect(home.installer.install(approval: true).failures == 0)
        let bin = home.paths.bin.path
        for status in home.installer.status() where status.installed {
            #expect(status.usesStablePath, "\(status.agent)")
        }
        for name in HookInstaller.runtimeScripts {
            #expect(FileManager.default.isExecutableFile(atPath: home.paths.script(name).path))
        }
        for path in [".claude/settings.json", ".codex/hooks.json", ".grok/hooks/vibebuddy.json", ".cursor/hooks.json"] {
            let text = String(decoding: try #require(home.bytes(path)), as: UTF8.self)
            #expect(text.contains(bin))
            #expect(!text.contains(Self.repo.appendingPathComponent("hooks").path), "\(path) names the source")
        }
        // An update that lost a script: launch puts it back without touching configs.
        let settings = home.bytes(".claude/settings.json")
        try FileManager.default.removeItem(at: home.paths.script("approval-hook.sh"))
        #expect(home.installer.refreshOnLaunch() != nil)
        #expect(FileManager.default.isExecutableFile(atPath: home.paths.script("approval-hook.sh").path))
        #expect(home.bytes(".claude/settings.json") == settings)
    }

    @Test("a missing runtime script aborts the install before any config is written")
    func missingScriptAborts() throws {
        var home = try Home()
        defer { home.remove() }
        try seed(home)
        let broken = home.url("broken-source")
        try FileManager.default.copyItem(at: Self.repo.appendingPathComponent("hooks"), to: broken)
        try FileManager.default.removeItem(at: broken.appendingPathComponent("cursor-followup.sh"))
        home.source = broken
        let before = Self.managed.map { home.bytes($0) }
        let report = home.installer.install()
        #expect(report.failures == 1)
        #expect(report.text.contains("cursor-followup.sh"))
        #expect(Self.managed.map { home.bytes($0) } == before)
    }

    // MARK: - Requirement 2: traceable writes

    @Test("each changing write is backed up with a timestamp, pruned, and recorded in the manifest")
    func backupsAndManifest() throws {
        var home = try Home()
        defer { home.remove() }
        let original = Data(#"{"model":"opus"}"#.utf8)
        try home.write(".claude/settings.json", #"{"model":"opus"}"#)
        #expect(home.installer.install([.claude]).failures == 0)
        let backups = home.paths.backups.appendingPathComponent("claude-\(home.paths.configKey(home.paths.claudeSettings))")
        func rotating() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: backups.path).filter { !$0.hasSuffix(".first") }.sorted()
        }
        let pinned = backups.appendingPathComponent("settings.json.first")
        #expect(FileManager.default.contents(atPath: pinned.path) == original)
        let first = try rotating()
        #expect(first.count == 1)
        // UTC timestamp plus a zero-padded counter: lexical order is chronological.
        #expect(first[0].range(of: #"^settings\.json\.\d{8}T\d{6}Z-\d{3}$"#, options: .regularExpression) != nil)
        #expect(FileManager.default.contents(atPath: backups.appendingPathComponent(first[0]).path) == original)
        // A no-op install writes no backup.
        _ = home.installer.install([.claude])
        #expect(try rotating().count == 1)
        // Pruned to the newest few; the pre-vibebuddy copy is never pruned.
        for step in 1...14 {
            if step > 4 { home.now = home.now.addingTimeInterval(1) }   // several writes in one second too
            _ = home.installer.install([.claude], approval: step % 2 == 1)
            if step % 2 == 0 { _ = home.installer.uninstall([.claude]) }
        }
        let kept = try rotating()
        #expect(kept.count == HookFileStore.maximumBackupsPerFile)
        #expect(kept == kept.sorted())
        #expect(!kept.contains(first[0]), "the oldest rotating copy is pruned")
        #expect(FileManager.default.contents(atPath: pinned.path) == original)
        _ = home.installer.install([.claude], approval: true)
        let manifest = HookFileStore(paths: home.paths).loadManifest()
        let entry = manifest.agents[home.paths.entryKey(.claude)]
        #expect(entry?.commands.contains { $0.contains("approval-hook.sh") } == true)
        #expect(entry?.config == home.paths.claudeSettings.path)
    }

    @Test("a symlinked settings file is written through the link")
    func symlinkedConfig() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write("dotfiles/claude-settings.json", #"{"model":"opus"}"#)
        try home.mkdir(".claude")
        try FileManager.default.createSymbolicLink(at: home.url(".claude/settings.json"),
                                                   withDestinationURL: home.url("dotfiles/claude-settings.json"))
        #expect(home.installer.install([.claude]).failures == 0)
        let attributes = try FileManager.default.attributesOfItem(atPath: home.url(".claude/settings.json").path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(String(decoding: try #require(home.bytes("dotfiles/claude-settings.json")), as: UTF8.self)
            .contains("vibebuddy-forward.sh"))
    }

    @Test("an unreadable settings file is reported and left untouched")
    func invalidConfigUntouched() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(".claude/settings.json", "{ not json")
        try home.write(".codex/hooks.json", #"{"hooks":{"Stop":"oops"}}"#)
        let report = home.installer.install([.claude, .codex])
        #expect(report.failures == 2)
        #expect(home.bytes(".claude/settings.json") == Data("{ not json".utf8))
        #expect(home.bytes(".codex/hooks.json") == Data(#"{"hooks":{"Stop":"oops"}}"#.utf8))
    }

    // MARK: - Requirement 3: recognise our entries, legacy commands included

    @Test("bundle-path and checkout-path entries migrate to the stable path with no duplicates")
    func legacyCommandsMigrate() throws {
        let home = try Home()
        defer { home.remove() }
        let bundle = "/Applications/VibeBuddyMacApp.app/Contents/Resources/hooks"
        let checkout = "/Users/someone/Projects/iOS-vibebuddy/hooks"
        try home.write(".claude/settings.json", """
        {"hooks":{
          "Stop":[{"hooks":[{"type":"command","command":"\(bundle)/vibebuddy-forward.sh","args":["claude"],"timeout":5,"async":true}]},
                  {"hooks":[{"type":"command","command":"say done"}]}],
          "Notification":[{"hooks":[{"type":"command","command":"curl -sS --max-time 3 -X POST --data-binary @- http://127.0.0.1:9877/hook 2>/dev/null || true"}]},
                          {"hooks":[{"type":"command","command":"curl -s -X POST http://127.0.0.1:3000/hook -d @-"}]}],
          "SessionStart":[{"hooks":[{"type":"command","command":"\\"\(checkout)/capture-terminal.sh\\" claude"}]}],
          "PermissionRequest":[{"matcher":"*","hooks":[{"type":"command","command":"\\"\(bundle)/approval-hook.sh\\"","timeout":30}]}]
        },
        "statusLine":{"type":"command","command":"\\"\(bundle)/vibebuddy-statusline.sh\\""}}
        """)
        try home.write(".codex/hooks.json", """
        {"hooks":{"Stop":[{"hooks":[{"command":"\\"\(bundle)/vibebuddy-forward.sh\\" codex","timeout":3,"type":"command"}]},
                          {"hooks":[{"command":"\(checkout)/vibebuddy-forward.sh codex","type":"command"}]},
                          {"hooks":[{"command":"/opt/other/vibebuddy-forward.sh.bak codex","type":"command"}]}]}}
        """)
        try home.write(".cursor/hooks.json", """
        {"version":1,"hooks":{"stop":[{"command":"\\"\(bundle)/cursor-followup.sh\\"","timeout":5}]}}
        """)
        try home.write(".grok/hooks/vibebuddy.json", """
        {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\\"\(checkout)/vibebuddy-forward.sh\\" grok","timeout":5}]}]}}
        """)
        #expect(home.installer.install([.claude, .codex, .cursor, .grok]).failures == 0)
        for path in [".claude/settings.json", ".codex/hooks.json", ".cursor/hooks.json", ".grok/hooks/vibebuddy.json"] {
            let text = String(decoding: try #require(home.bytes(path)), as: UTF8.self)
            #expect(!text.contains(bundle), "\(path) kept a bundle path")
            #expect(!text.contains(checkout), "\(path) kept a checkout path")
            // Written under another VIBEBUDDY_PORT: still recognised as ours.
            #expect(!text.contains("9877/hook"), "\(path) kept the inline curl")
        }
        let claude = try home.json(".claude/settings.json")
        #expect(Self.commands(claude, "Stop").filter { $0.contains("vibebuddy-forward.sh") }.count == 1)
        #expect(Self.commands(claude, "Stop").contains("say done"))
        // The user's own local webhook is not the early installer's command, whatever its path.
        #expect(Self.commands(claude, "Notification").contains("curl -s -X POST http://127.0.0.1:3000/hook -d @-"))
        #expect(Self.commands(claude, "Notification").filter { $0.contains("vibebuddy-forward.sh") }.count == 1)
        #expect(Self.commands(claude, "PermissionRequest").filter { $0.contains("approval-hook.sh") }.count == 1)
        // The re-pointed wrapper never became its own saved original.
        #expect(!FileManager.default.fileExists(atPath: home.paths.statusLineOriginal.path))
        let codex = try home.json(".codex/hooks.json")
        let stop = Self.commands(codex, "Stop")
        #expect(stop.filter { $0.contains("vibebuddy-forward.sh\" codex") }.count == 1)
        // Not ours: a different script name that merely starts the same.
        #expect(stop.contains("/opt/other/vibebuddy-forward.sh.bak codex"))
        #expect(Self.cursorEntries(try home.json(".cursor/hooks.json"), "stop").count == 1)
    }

    // MARK: - Requirement 4: version-gated Claude events

    @Test("Claude events follow the installed version; unknown means the conservative set")
    func versionGatedEvents() throws {
        var home = try Home()
        defer { home.remove() }
        func ourEvents() throws -> Set<String> {
            let doc = try home.json(".claude/settings.json")
            return Set((doc["hooks"] as? [String: Any] ?? [:]).keys.filter { event in
                Self.commands(doc, event).contains { $0.contains("vibebuddy-forward.sh") } })
        }
        let core: Set<String> = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                                 "PostToolUse", "Notification", "SubagentStart", "SubagentStop",
                                 "PreCompact", "Stop", "SessionEnd"]
        try home.write(".claude/settings.json",
            #"{"hooks":{"PostModelSwitch":[{"hooks":[{"type":"command","command":"echo user-switch"}]}]}}"#)
        // A fresh install with no version to go on: the core set.
        home.version = nil
        _ = home.installer.install([.claude])
        #expect(try ourEvents() == core)

        home.version = ClaudeCodeVersion(2, 1, 280)
        _ = home.installer.install([.claude])
        #expect(try ourEvents() == Set(ClaudeHooks.eventMinimums.map(\.event)))
        let full = home.bytes(".claude/settings.json")

        // A Repair that cannot find `claude` (GUI PATH, slow cold start)
        // leaves a working install exactly as it was.
        home.version = nil
        _ = home.installer.install([.claude])
        #expect(home.bytes(".claude/settings.json") == full)

        // Only a known older version withdraws what it does not know.
        home.version = ClaudeCodeVersion(2, 1, 80)
        let older = home.installer.install([.claude])
        #expect(older.failures == 0)
        let events = try ourEvents()
        #expect(events.contains("StopFailure") && events.contains("PostCompact"))
        for newer in ["PostModelSwitch", "PostToolBatch", "CwdChanged", "TaskCreated", "PermissionDenied", "PostToolUseFailure"] {
            #expect(!events.contains(newer), "\(newer) written for 2.1.80")
        }
        // The user's own hook on an event we withdrew stays.
        #expect(Self.commands(try home.json(".claude/settings.json"), "PostModelSwitch") == ["echo user-switch"])
    }

    @Test("Claude commands are shell form with a quoted path (Grok's bridge has no `args`)")
    func claudeShellForm() throws {
        let home = try Home()
        defer { home.remove() }
        let old = "/Applications/VibeBuddyMacApp.app/Contents/Resources/hooks/vibebuddy-forward.sh"
        try home.write(".claude/settings.json",
            #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"\#(old)","args":["claude"],"timeout":5,"async":true}]}]}}"#)
        _ = home.installer.install([.claude], approval: true)
        let doc = try home.json(".claude/settings.json")
        for event in (doc["hooks"] as? [String: Any] ?? [:]).keys {
            for hook in Self.handlers(doc, event) {
                #expect(hook["args"] == nil, "\(event) kept exec form")
                let command = try #require(hook["command"] as? String)
                let argv = try #require(ShellWords.split(command))
                #expect(argv[0].hasPrefix(home.paths.bin.path), "\(event): \(command)")
                #expect(FileManager.default.isExecutableFile(atPath: argv[0]))
            }
        }
        let status = try #require(doc["statusLine"] as? [String: Any])
        #expect(ShellWords.split(try #require(status["command"] as? String))
                == [home.paths.script("vibebuddy-statusline.sh").path, home.paths.claudeKey])
    }

    @Test("version strings parse and compare numerically")
    func versionParsing() {
        #expect(ClaudeCodeVersion(parsing: "2.1.280 (Claude Code)") == ClaudeCodeVersion(2, 1, 280))
        #expect(ClaudeCodeVersion(parsing: "garbage") == nil)
        #expect(ClaudeCodeVersion(2, 1, 99) < ClaudeCodeVersion(2, 1, 100))
        #expect(ClaudeCodeVersion.probe(environment: ["VIBEBUDDY_CLAUDE_VERSION": "2.0.1"],
                                        home: URL(fileURLWithPath: "/nonexistent")) == ClaudeCodeVersion(2, 0, 1))
    }

    @Test("the version probe finds a claude whose interpreter lives beside it, off the GUI PATH")
    func probePath() throws {
        let home = try Home()
        defer { home.remove() }
        // Stands in for an npm `claude` (`#!/usr/bin/env node`) under launchd's bare PATH.
        try home.write(".local/bin/fake-node", "#!/bin/sh\necho '2.1.99 (Claude Code)'\n")
        try home.write(".local/bin/claude", "#!/usr/bin/env fake-node\n")
        for name in ["fake-node", "claude"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.url(".local/bin/\(name)").path)
        }
        #expect(ClaudeCodeVersion.probe(environment: ["PATH": "/usr/bin:/bin"], home: home.root)
                == ClaudeCodeVersion(2, 1, 99))
    }

    // MARK: - Two Claude config directories

    @Test("two Claude config dirs keep separate status lines, manifest entries and bin/ lifetime")
    func twoClaudeConfigDirs() throws {
        var home = try Home()
        defer { home.remove() }
        try home.write(".claude/settings.json", #"{"statusLine":{"type":"command","command":"personal-sl"}}"#)
        try home.write(".claude-work/settings.json", #"{"statusLine":{"type":"command","command":"work-sl"}}"#)
        #expect(home.installer.install([.claude]).failures == 0)
        let personalKey = home.paths.claudeKey
        home.variables["CLAUDE_CONFIG_DIR"] = home.url(".claude-work").path
        #expect(home.installer.install([.claude]).failures == 0)
        let workKey = home.paths.claudeKey
        #expect(personalKey != workKey)

        // Each wrapper runs its own original.
        for (path, expected) in [(".claude/settings.json", "personal-sl"), (".claude-work/settings.json", "work-sl")] {
            let command = try #require((try home.json(path)["statusLine"] as? [String: Any])?["command"] as? String)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.root.path, "VIBEBUDDY_TOKEN": "",
                                   "VIBEBUDDY_SUPPORT_DIR": home.paths.support.path]
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            // `personal-sl` / `work-sl` are not real commands: the shell names them in its error.
            process.standardError = output
            try process.run()
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(text.contains(expected), "\(path) ran: \(text)")
            #expect(!text.contains(expected == "work-sl" ? "personal-sl" : "work-sl"))
        }

        // Uninstall with the default environment: only ~/.claude changes.
        home.variables = [:]
        #expect(home.installer.uninstall([.claude]).failures == 0)
        #expect((try home.json(".claude/settings.json")["statusLine"] as? [String: Any])?["command"] as? String == "personal-sl")
        let work = try home.json(".claude-work/settings.json")
        #expect(((work["statusLine"] as? [String: Any])?["command"] as? String)?.contains("vibebuddy-statusline.sh") == true)
        #expect(FileManager.default.isExecutableFile(atPath: home.paths.script("vibebuddy-statusline.sh").path),
                "bin/ must stay while .claude-work still names it")
        let manifest = HookFileStore(paths: home.paths).loadManifest()
        #expect(manifest.agents.keys.sorted() == ["claude:" + HookPaths.canonicalPath(home.url(".claude-work/settings.json"))])

        // Then the work directory: its own original comes back and bin/ goes.
        home.variables["CLAUDE_CONFIG_DIR"] = home.url(".claude-work").path
        #expect(home.installer.uninstall([.claude]).failures == 0)
        #expect((try home.json(".claude-work/settings.json")["statusLine"] as? [String: Any])?["command"] as? String == "work-sl")
        #expect(!FileManager.default.fileExists(atPath: home.paths.bin.path))
    }

    @Test("a pre-C-1 ~/.claude wrapper and its unkeyed saved original migrate to the keyed files")
    func legacyStatusLineFilesMigrate() throws {
        let home = try Home()
        defer { home.remove() }
        let old = "\\\"/Applications/VibeBuddyMacApp.app/Contents/Resources/hooks/vibebuddy-statusline.sh\\\""
        try home.write(".claude/settings.json", #"{"statusLine":{"type":"command","command":"\#(old)","padding":4}}"#)
        try FileManager.default.createDirectory(at: home.paths.support, withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"~/my-line","padding":4}}"#.utf8).write(to: home.paths.legacyStatusLineOriginal)
        try Data("~/my-line".utf8).write(to: home.paths.legacyStatusLineOriginalCommand)
        #expect(home.installer.install([.claude]).failures == 0)
        #expect(FileManager.default.contents(atPath: home.paths.statusLineOriginalCommand.path) == Data("~/my-line".utf8))
        #expect(home.installer.uninstall([.claude]).failures == 0)
        let restored = try #require(try home.json(".claude/settings.json")["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "~/my-line" && restored["padding"] as? Int == 4)
        for url in [home.paths.statusLineOriginal, home.paths.statusLineOriginalCommand,
                    home.paths.legacyStatusLineOriginal, home.paths.legacyStatusLineOriginalCommand] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("one Claude dir reached through a symlink and through CLAUDE_CONFIG_DIR gets one key")
    func symlinkedClaudeDirOneKey() throws {
        var home = try Home()
        defer { home.remove() }
        try home.write("dotfiles/claude/settings.json", #"{"statusLine":{"type":"command","command":"my-sl"}}"#)
        try FileManager.default.createSymbolicLink(at: home.url(".claude"), withDestinationURL: home.url("dotfiles/claude"))
        let viaLink = home.paths
        home.variables["CLAUDE_CONFIG_DIR"] = home.url("dotfiles/claude").path
        let viaVariable = home.paths
        #expect(viaLink.claudeKey == viaVariable.claudeKey)
        #expect(viaLink.entryKey(.claude) == viaVariable.entryKey(.claude))
        #expect(viaVariable.isDefaultClaudeDirectory)
        // A config file that does not exist yet still resolves through its parent link.
        #expect(viaLink.configKey(home.url(".claude/missing.json")) == viaVariable.configKey(home.url("dotfiles/claude/missing.json")))

        // Installed one way, uninstalled the other: the saved original is found.
        home.variables = [:]
        #expect(home.installer.install([.claude]).failures == 0)
        home.variables["CLAUDE_CONFIG_DIR"] = home.url("dotfiles/claude").path
        #expect(home.installer.uninstall([.claude]).failures == 0)
        #expect((try home.json("dotfiles/claude/settings.json")["statusLine"] as? [String: Any])?["command"] as? String == "my-sl")
        #expect(HookFileStore(paths: home.paths).loadManifest().agents.isEmpty)
    }

    @Test("a status line saved under #266's unresolved key is carried over and restored")
    func unresolvedKeyStatusLineMigrates() throws {
        var home = try Home()
        defer { home.remove() }
        try home.mkdir("real-claude")
        try FileManager.default.createSymbolicLink(at: home.url("linked-claude"), withDestinationURL: home.url("real-claude"))
        home.variables["CLAUDE_CONFIG_DIR"] = home.url("linked-claude").path
        let old = try #require(home.paths.unresolvedKeyStatusLineOriginals.first)
        let oldWrapper = ShellWords.quoted(home.paths.script("vibebuddy-statusline.sh").path) + " "
            + home.paths.unresolvedConfigKey(home.paths.claudeSettings)
        try home.write("real-claude/settings.json", String(decoding: OrderedJSON.obj(["statusLine": .obj([
            "type": .string("command"), "command": .string(oldWrapper)])]).serialized(), as: UTF8.self))
        try FileManager.default.createDirectory(at: home.paths.support, withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"mine"}}"#.utf8).write(to: old.json)
        try Data("mine".utf8).write(to: old.command)
        #expect(home.installer.enableStatusLine().failures == 0)
        let wrapper = try #require((try home.json("real-claude/settings.json")["statusLine"] as? [String: Any])?["command"] as? String)
        #expect(wrapper.hasSuffix(" " + home.paths.claudeKey))
        #expect(FileManager.default.contents(atPath: home.paths.statusLineOriginalCommand.path) == Data("mine".utf8))
        #expect(home.installer.uninstall([.claude]).failures == 0)
        #expect((try home.json("real-claude/settings.json")["statusLine"] as? [String: Any])?["command"] as? String == "mine")
        for url in [old.json, old.command, home.paths.statusLineOriginal, home.paths.statusLineOriginalCommand] {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("bare manifest and uninstall keys from b95d7ce9 load as path-qualified keys")
    func bareManifestKeysMigrate() throws {
        let home = try Home()
        defer { home.remove() }
        try seed(home)
        try FileManager.default.createDirectory(at: home.paths.support, withIntermediateDirectories: true)
        let codexHooks = home.paths.codexHooks.path
        try Data("""
        {"version":1,"agents":{
          "codex":{"config":"\(codexHooks)","commands":["old-codex"],"approval":false,"installedAt":"2026-09-20T00:00:00Z"},
          "claude":{"config":"\(home.paths.claudeSettings.path)","commands":["bare"],"approval":false,"installedAt":"2026-09-23T00:00:00Z"},
          "claude:\(home.paths.claudeSettings.path)":{"config":"\(home.paths.claudeSettings.path)","commands":["keyed"],"approval":true,"installedAt":"2026-09-21T00:00:00Z"}
        }}
        """.utf8).write(to: home.paths.manifest)
        try Data(#"{"uninstalled":["grok","grok"]}"#.utf8).write(to: home.paths.state)
        let store = HookFileStore(paths: home.paths)
        let manifest = store.loadManifest()
        #expect(manifest.agents[home.paths.entryKey(.codex)]?.commands == ["old-codex"])
        // Same config: commands merge, the path-qualified entry supplies the rest.
        #expect(manifest.agents[home.paths.entryKey(.claude)]?.commands == ["bare", "keyed"])
        #expect(manifest.agents[home.paths.entryKey(.claude)]?.approval == true)
        #expect(manifest.agents.keys.allSatisfy { $0.contains(":") })
        #expect(store.loadState().uninstalled == [home.paths.entryKey(.grok)])
        // The remembered Grok uninstall still holds, and old commands are still recognised as ours.
        #expect(home.installer.status().first { $0.agent == .grok }?.explicitlyUninstalled == true)
        #expect(home.installer.install([.codex]).failures == 0)
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.paths.manifest)) as? [String: Any])
        #expect((raw["agents"] as? [String: Any])?.keys.allSatisfy { $0.contains(":") } == true)
    }

    @Test("a config path with no symlink keeps #266's key: nothing to carry over")
    func unsymlinkedKeyUnchanged() throws {
        let home = try Home()
        defer { home.remove() }
        try home.mkdir(".claude")
        // The owner's case: a real home directory, already canonical (the test
        // temp dir itself sits behind /var -> /private/var).
        let real = URL(fileURLWithPath: HookPaths.canonicalPath(home.root), isDirectory: true)
        let paths = HookPaths(HookInstallerEnvironment(home: real, claudeVersion: { nil }))
        #expect(paths.configKey(paths.claudeSettings) == paths.unresolvedConfigKey(paths.claudeSettings))
        #expect(paths.unresolvedKeyStatusLineOriginals.isEmpty)
        #expect(paths.entryKey(.claude) == "claude:" + paths.claudeSettings.standardizedFileURL.path)
    }

    @Test("a Cursor hooks.json that is not valid JSON is refused, never replaced")
    func cursorUnreadableRefused() throws {
        let home = try Home()
        defer { home.remove() }
        let text = "{\"version\":1,\"hooks\":{\"stop\":[{\"command\":\"./mine.sh\"},]}} // trailing comma\n"
        try home.write(".cursor/hooks.json", text)
        let report = home.installer.install([.cursor], approval: true)
        #expect(report.failures == 1)
        #expect(home.bytes(".cursor/hooks.json") == Data(text.utf8))
        #expect(home.installer.uninstall([.cursor]).failures == 1)
        #expect(home.bytes(".cursor/hooks.json") == Data(text.utf8))
    }

    @Test("the script source follows the running binary: explicit, its own bundle or checkout, then the installed app")
    func scriptSourceOrder() throws {
        let home = try Home()
        defer { home.remove() }
        func scripts(_ relative: String) throws -> URL {
            for name in HookInstaller.runtimeScripts { try home.write("\(relative)/hooks/\(name)", "#!/bin/sh\n") }
            return home.url(relative)
        }
        let checkout = try scripts("checkout")
        let other = try scripts("other-checkout")
        let app = try scripts("App.app/Contents/Resources")
        let own = try scripts("Own.app/Contents/Resources")
        let exe = checkout.appendingPathComponent("VibeBuddyMac/.build/debug/vibebuddyd")
        let loose = home.url("usr/local/bin/vibebuddyd")
        func hooks(_ root: URL) -> String { root.appendingPathComponent("hooks").standardizedFileURL.path }
        func locate(explicit: String? = nil, env: [String: String] = [:], executable: URL? = nil,
                    cwd: URL? = nil, bundle: URL? = nil, installed: URL?) -> String? {
            HookScriptSource.locate(explicit: explicit, environment: env, executable: executable ?? exe,
                                    workingDirectory: cwd ?? other, bundleResources: bundle,
                                    installedApp: installed)?.standardizedFileURL.path
        }
        // W1: a checkout build installs its own scripts even with an (older) app installed.
        #expect(locate(installed: app) == hooks(checkout))
        #expect(locate(bundle: own, installed: app) == hooks(own))
        // A binary with no bundle or checkout of its own: the installed app, then the working directory.
        #expect(locate(executable: loose, installed: app) == hooks(app))
        #expect(locate(executable: loose, installed: nil) == hooks(other))
        #expect(locate(env: ["VIBEBUDDY_HOOKS_DIR": hooks(other)], installed: app) == hooks(other))
        #expect(locate(explicit: hooks(app), installed: nil) == hooks(app))
        #expect(locate(explicit: home.url("nowhere").path, installed: app) == nil)
        // A checkout whose scripts differ from the installed app's is flagged; the app itself is not.
        #expect(HookScriptSource.differingInstalledApp(checkout.appendingPathComponent("hooks"), installedApp: app) == nil)
        try home.write("checkout/hooks/approval-hook.sh", "#!/bin/sh\n# newer\n")
        #expect(HookScriptSource.differingInstalledApp(checkout.appendingPathComponent("hooks"), installedApp: app) != nil)
        #expect(HookScriptSource.differingInstalledApp(app.appendingPathComponent("hooks"), installedApp: app) == nil)
        #expect(HookScriptSource.differingInstalledApp(checkout.appendingPathComponent("hooks"), installedApp: nil) == nil)
    }

    // MARK: - Requirement 5: status line recursion guard

    @Test("the wrapper never saves itself as the original, and a poisoned saved command is cleared")
    func statusLineRecursionGuard() throws {
        let home = try Home()
        defer { home.remove() }
        let legacy = "\"/Applications/VibeBuddyMacApp.app/Contents/Resources/hooks/vibebuddy-statusline.sh\""
        try home.write(".claude/settings.json", #"{"statusLine":{"type":"command","command":"\#(legacy.replacingOccurrences(of: "\"", with: "\\\""))","padding":3}}"#)
        try FileManager.default.createDirectory(at: home.paths.support, withIntermediateDirectories: true)
        try Data("sh /x/vibebuddy-statusline.sh".utf8).write(to: home.paths.statusLineOriginalCommand)
        #expect(home.installer.enableStatusLine().failures == 0)
        let line = try #require(try home.json(".claude/settings.json")["statusLine"] as? [String: Any])
        #expect((line["command"] as? String)?.contains(home.paths.bin.path) == true)
        #expect(line["padding"] as? Int == 3)
        #expect(FileManager.default.contents(atPath: home.paths.statusLineOriginalCommand.path) == Data())
        #expect(!FileManager.default.fileExists(atPath: home.paths.statusLineOriginal.path))
        // Enabling again changes nothing.
        let before = home.bytes(".claude/settings.json")
        _ = home.installer.enableStatusLine()
        #expect(home.bytes(".claude/settings.json") == before)
    }

    @Test("uninstall never deletes a status line it cannot restore")
    func uninstallWithoutBackup() throws {
        let home = try Home()
        defer { home.remove() }
        let wrapper = home.paths.script("vibebuddy-statusline.sh").path
        try home.write(".claude/settings.json", #"{"statusLine":{"type":"command","command":"\"\#(wrapper)\"","padding":2}}"#)
        let report = home.installer.uninstall([.claude])
        #expect(report.text.contains("status line left in place"))
        #expect((try home.json(".claude/settings.json")["statusLine"] as? [String: Any])?["padding"] as? Int == 2)
        // With only the plain command saved, that command comes back.
        try FileManager.default.createDirectory(at: home.paths.support, withIntermediateDirectories: true)
        try Data("~/bin/my-line".utf8).write(to: home.paths.statusLineOriginalCommand)
        _ = home.installer.uninstall([.claude])
        let restored = try #require(try home.json(".claude/settings.json")["statusLine"] as? [String: Any])
        #expect(restored["command"] as? String == "~/bin/my-line" && restored["padding"] as? Int == 2)
        // A status line that is not ours is never touched.
        try home.write(".claude/settings.json", #"{"statusLine":{"type":"command","command":"mine"}}"#)
        let mine = home.bytes(".claude/settings.json")
        _ = home.installer.uninstall([.claude])
        #expect(home.bytes(".claude/settings.json") == mine)
    }

    // MARK: - Requirement 6: environment overrides

    @Test("CLAUDE_CONFIG_DIR, CODEX_HOME, CURSOR_HOME and XDG_CONFIG_HOME redirect install, status and detection")
    func environmentOverrides() throws {
        var home = try Home()
        defer { home.remove() }
        home.variables = ["CLAUDE_CONFIG_DIR": home.url("alt/claude").path, "CODEX_HOME": home.url("alt/codex").path,
                          "CURSOR_HOME": home.url("alt/cursor").path, "XDG_CONFIG_HOME": home.url("alt/xdg").path]
        for dir in ["alt/claude", "alt/codex", "alt/cursor", "alt/xdg/opencode"] { try home.mkdir(dir) }
        let report = home.installer.install()
        #expect(report.failures == 0)
        #expect(Set(report.touched) == [.claude, .codex, .cursor, .opencode])
        for path in ["alt/claude/settings.json", "alt/codex/hooks.json", "alt/cursor/hooks.json", "alt/xdg/opencode/plugins/vibebuddy.js"] {
            #expect(home.exists(path), "\(path)")
        }
        for path in [".claude", ".codex", ".cursor", ".config"] { #expect(!home.exists(path), "\(path)") }
        let detected = EnvironmentDetector.detect(EnvironmentDetector.defaultCLIs(home: home.root.path, environment: home.variables))
        for name in ["claude", "codex", "cursor", "opencode"] {
            #expect(detected.first { $0.name == name }?.hookInjected == true, "\(name)")
        }
        #expect(detected.first { $0.name == "claude" }?.statusLineWired == true)
        #expect(home.installer.status().filter(\.installed).map(\.agent).sorted { $0.rawValue < $1.rawValue }
                == [.claude, .codex, .cursor, .opencode])
    }

    // MARK: - Requirement 7: remembered uninstall

    @Test("an explicit uninstall is remembered: launches do nothing until an explicit install")
    func rememberedUninstall() throws {
        let home = try Home()
        defer { home.remove() }
        try seed(home)
        _ = home.installer.install()
        #expect(home.installer.uninstall().failures == 0)
        #expect(!FileManager.default.fileExists(atPath: home.paths.bin.path))
        #expect(home.installer.refreshOnLaunch() == nil)
        #expect(!FileManager.default.fileExists(atPath: home.paths.bin.path))
        #expect(home.installer.status().allSatisfy { $0.explicitlyUninstalled && !$0.installed })
        _ = home.installer.install([.codex])
        let status = home.installer.status()
        #expect(status.first { $0.agent == .codex }?.explicitlyUninstalled == false)
        #expect(status.first { $0.agent == .claude }?.explicitlyUninstalled == true)
        try FileManager.default.removeItem(at: home.paths.bin)
        #expect(home.installer.refreshOnLaunch() != nil)
        #expect(FileManager.default.fileExists(atPath: home.paths.script("vibebuddy-forward.sh").path))
    }

    // MARK: - Requirement 8: config.toml untouched, Cursor keeps version 1

    @Test("a tricky config.toml is byte-identical after install, approval and uninstall")
    func tomlRoundTrip() throws {
        let home = try Home()
        defer { home.remove() }
        let toml = #"""
        # comment with [features] and "quotes"
        model = "gpt-5.5"   # trailing
        notify = ["/Applications/A B.app/Contents/MacOS/n", "turn-ended"]
        "quoted.key" = 'literal \n'
        dotted.table.key = 1_000
        date = 1979-05-27T07:32:00Z
        inline = { a = 1, "b c" = [1, 2, { d = "e" }] }

        [features]
        codex_hooks = true
        web_search = true

        [[mcp_servers.list]]
        name = "one"

        [profiles."with.dot"]
        features.hooks = false

        [notes]
        text = """
        [features]
        hooks = false
        """
        raw = '''
        no escapes \here
        '''
        """# + "\n"
        try home.write(".codex/config.toml", toml)
        let original = try #require(home.bytes(".codex/config.toml"))
        _ = home.installer.install([.codex])
        _ = home.installer.install([.codex], approval: true)
        _ = home.installer.install([.codex])
        _ = home.installer.uninstall([.codex])
        #expect(home.bytes(".codex/config.toml") == original)
        #expect(!home.exists(".codex/hooks.json"), "a hooks.json holding only our hooks is removed")
    }

    @Test("Cursor's hooks.json gains or keeps version 1; a file that was only ours is removed")
    func cursorVersionKey() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(".cursor/hooks.json", #"{"hooks":{"stop":[{"command":"mine"}]},"extra":{"k":1.50}}"#)
        _ = home.installer.install([.cursor])
        var doc = try home.json(".cursor/hooks.json")
        #expect(doc["version"] as? Int == 1)
        #expect(String(decoding: try #require(home.bytes(".cursor/hooks.json")), as: UTF8.self).contains("1.50"))
        _ = home.installer.uninstall([.cursor])
        doc = try home.json(".cursor/hooks.json")
        #expect(doc["version"] as? Int == 1)
        #expect((doc["hooks"] as? [String: [[String: Any]]])?["stop"]?.first?["command"] as? String == "mine")
        #expect(doc["extra"] != nil)

        try home.write(".cursor/hooks.json", #"{"version":1,"hooks":{}}"#)
        _ = home.installer.install([.cursor])
        _ = home.installer.uninstall([.cursor])
        #expect(!home.exists(".cursor/hooks.json"))
    }

    // MARK: - OpenCode and Antigravity

    @Test("OpenCode: a foreign plugin is set aside and restored; an older vibebuddy plugin is replaced")
    func opencodePlugin() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(".config/opencode/plugins/vibebuddy.js", "// someone else's plugin\n")
        _ = home.installer.install([.opencode])
        #expect(String(decoding: try #require(home.bytes(".config/opencode/plugins/vibebuddy.js")), as: UTF8.self)
            .contains("VibeBuddy OpenCode plugin"))
        _ = home.installer.uninstall([.opencode])
        #expect(home.bytes(".config/opencode/plugins/vibebuddy.js") == Data("// someone else's plugin\n".utf8))

        try home.write(".config/opencode/plugins/vibebuddy.js", "// VibeBuddy OpenCode plugin — an old version\n")
        try? FileManager.default.removeItem(at: home.url(".config/opencode/plugins/vibebuddy.js.vibebuddy-backup"))
        _ = home.installer.install([.opencode])
        #expect(!home.exists(".config/opencode/plugins/vibebuddy.js.vibebuddy-backup"))
        _ = home.installer.uninstall([.opencode])
        #expect(!home.exists(".config/opencode/plugins/vibebuddy.js"))
    }

    @Test("Antigravity: only the named vibebuddy spec is managed")
    func antigravity() throws {
        let home = try Home()
        defer { home.remove() }
        try home.write(".gemini/antigravity-cli/hooks.json", #"{"mine":{"Stop":[{"type":"command","command":"x"}]}}"#)
        _ = home.installer.install([.antigravity])
        let doc = try home.json(".gemini/antigravity-cli/hooks.json")
        #expect(doc["mine"] != nil)
        let spec = try #require(doc["vibebuddy"] as? [String: Any])
        #expect(Set(spec.keys) == Set(AntigravityHooks.events))
        _ = home.installer.uninstall([.antigravity])
        #expect(Set(try home.json(".gemini/antigravity-cli/hooks.json").keys) == ["mine"])
    }

    // MARK: - Installer output agrees with the Settings diagnostics

    @Test("what the installer writes is what ObservationHealthDetector recognises")
    func detectorAgreement() throws {
        var home = try Home()
        defer { home.remove() }
        // A support directory with a space and an apostrophe in its path.
        let support = home.url("support with space's")
        home.variables["VIBEBUDDY_SUPPORT_DIR"] = support.path
        home.variables["GROK_HOME"] = home.url(".grok").path
        try home.write(".claude/settings.json", #"{"hooks":{"Stop":[{"hooks":[{"command":"echo user-hook"}]}]}}"#)
        try home.mkdir(".codex")
        try home.mkdir(".grok")
        try home.mkdir(".cursor")
        for (version, approval) in [(ClaudeCodeVersion(2, 1, 261), false), (nil, true)] {
            home.version = version
            #expect(home.installer.install([.claude, .codex, .grok, .cursor], approval: approval).failures == 0)
            let rows = ObservationHealthDetector.detect(home: home.root, signals: [], now: Date(),
                                                        grokHome: home.url(".grok"))
            for agent in rows {
                let hook = try #require(agent.sources.first { $0.source == .hook })
                #expect(hook.reasonCode == "awaitingActivity", "\(agent.agent) \(approval)")
                // Cursor can only ask for attention through its approval gate.
                let expected: [ObservationEventCoverage] = agent.agent == .cursor && !approval
                    ? [.lifecycle, .turn, .tool] : ObservationEventCoverage.allCases
                #expect(hook.configuredCoverage == expected, "\(agent.agent)")
            }
        }
    }
}

@Suite("OrderedJSON")
struct OrderedJSONTests {
    @Test("Python json.dumps(indent=2) output round-trips byte for byte")
    func pythonLayout() throws {
        let text = """
        {
          "z": 1.0,
          "a": [],
          "o": {},
          "s": "caf\u{00e9} / \\"q\\" \\\\ \\n \\u0001",
          "n": null,
          "b": [
            true,
            false,
            -2.5e-3
          ]
        }

        """
        let value = try OrderedJSON.parse(Data(text.utf8))
        #expect(value.keys == ["z", "a", "o", "s", "n", "b"])
        #expect(value.serialized() == Data(text.utf8))
    }

    @Test("escapes, surrogate pairs and errors")
    func escapes() throws {
        let value = try OrderedJSON.parse(Data(#"{"e":"\ud83d\ude00\/x"}"#.utf8))
        #expect(value["e"]?.stringValue == "😀/x")
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data("{\"a\":1,}".utf8)) }
        // A lone surrogate refuses the file instead of becoming U+FFFD.
        for lone in [#"{"e":"\ud83d"}"#, #"{"e":"\ud83dx"}"#, #"{"e":"\ude00"}"#, #"{"e":"\ud83d\u0041"}"#] {
            #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data(lone.utf8)) }
        }
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(Data("[1] 2".utf8)) }
    }
}
