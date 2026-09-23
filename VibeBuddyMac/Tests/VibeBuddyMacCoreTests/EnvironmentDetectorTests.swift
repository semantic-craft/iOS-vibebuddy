import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("EnvironmentDetector — onboarding CLI/hook status (issue 05)")
struct EnvironmentDetectorTests {

    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vbenv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a CLI with no config is not configured and not injected")
    func absent() {
        let dir = tempDir()
        let spec = CLISpec(name: "claude", configPath: dir.appendingPathComponent("missing.json").path)
        let status = EnvironmentDetector.detect([spec]).first!
        #expect(status.configured == false)
        #expect(status.hookInjected == false)
    }

    /// Claude's status line is the only source of its account quota, and it is
    /// wired separately from the lifecycle hooks — it went missing once while
    /// the hooks kept working, and nothing said so.
    @Test("the Claude status line is reported separately from the hooks")
    func statusLineWiring() throws {
        let dir = tempDir()
        let cfg = dir.appendingPathComponent("settings.json")
        let spec = CLISpec(name: "claude", configPath: cfg.path, statusLinePath: cfg.path)

        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"curl 127.0.0.1:9876/hook"}]}]}}"#
            .write(to: cfg, atomically: true, encoding: .utf8)
        let unwired = EnvironmentDetector.detect([spec]).first!
        #expect(unwired.hookInjected)
        #expect(unwired.statusLineWired == false)

        // A path with no hook marker in it, so the two facts cannot be confused.
        try #"{"statusLine":{"type":"command","command":"/x/vb/vibebuddy-statusline.sh"}}"#
            .write(to: cfg, atomically: true, encoding: .utf8)
        let wired = EnvironmentDetector.detect([spec]).first!
        #expect(wired.statusLineWired == true)
        // The lifecycle hooks are gone from this file, and that stays separate.
        #expect(wired.hookInjected == false)

        // The marker has to be the status line's own command, not merely
        // present in the file: a hook that mentions the script is not a wired
        // status line.
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/vb/vibebuddy-statusline.sh"}]}]}}"#
            .write(to: cfg, atomically: true, encoding: .utf8)
        #expect(EnvironmentDetector.detect([spec]).first!.statusLineWired == false)

        // A CLI with no status line to wire reports nothing rather than false.
        #expect(EnvironmentDetector.detect([CLISpec(name: "codex", configPath: cfg.path)])
            .first!.statusLineWired == nil)
    }

    @Test("a config without the vibebuddy marker is configured but not injected")
    func configuredNotInjected() throws {
        let dir = tempDir()
        let cfg = dir.appendingPathComponent("settings.json")
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}"#
            .write(to: cfg, atomically: true, encoding: .utf8)
        let status = EnvironmentDetector.detect([CLISpec(name: "claude", configPath: cfg.path)]).first!
        #expect(status.configured)
        #expect(status.hookInjected == false)
    }

    @Test("a user's own hook under a hooks/ directory is not mistaken for vibebuddy's")
    func userHooksDirectoryIsNotInjected() throws {
        let dir = tempDir()
        let cfg = dir.appendingPathComponent("settings.json")
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/Users/me/.claude/hooks/lint.sh"}]}]}}"#
            .write(to: cfg, atomically: true, encoding: .utf8)
        #expect(EnvironmentDetector.detect([CLISpec(name: "claude", configPath: cfg.path)]).first?.hookInjected == false)
        try "// VibeBuddy OpenCode plugin — reports OpenCode lifecycle events".write(to: cfg, atomically: true, encoding: .utf8)
        #expect(EnvironmentDetector.detect([CLISpec(name: "opencode", configPath: cfg.path)]).first?.hookInjected == true)
    }

    @Test("a config carrying the forward marker is detected as injected")
    func injected() throws {
        let dir = tempDir()
        let cfg = dir.appendingPathComponent("settings.json")
        try #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"curl 127.0.0.1:9876/hook"}]}]}}"#
            .write(to: cfg, atomically: true, encoding: .utf8)
        let status = EnvironmentDetector.detect([CLISpec(name: "claude", configPath: cfg.path)]).first!
        #expect(status.configured)
        #expect(status.hookInjected)
    }

    @Test("Codex lifecycle hooks are detected as injected")
    func codexInjected() throws {
        let dir = tempDir()
        let cfg = dir.appendingPathComponent("config.toml")
        let hooks = dir.appendingPathComponent("hooks.json")
        try "model = \"gpt\"\n".write(to: cfg, atomically: true, encoding: .utf8)
        try #"{"hooks":{"Stop":[{"hooks":[{"command":"/app/vibebuddy-forward.sh codex"}]}]}}"#
            .write(to: hooks, atomically: true, encoding: .utf8)
        let spec = CLISpec(name: "codex", configPath: cfg.path, hookPath: hooks.path)
        let status = EnvironmentDetector.detect([spec]).first!
        #expect(status.configured)
        #expect(status.hookInjected)
    }

    @Test("directory-based CLIs inspect only their installed hook file",
          arguments: ["grok", "antigravity", "opencode", "cursor"])
    func explicitHookFile(name: String) throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = try #require(EnvironmentDetector.defaultCLIs(home: dir.path).first { $0.name == name })
        let config = URL(fileURLWithPath: spec.configPath)
        let history = config.appendingPathComponent("history/session.json")
        try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "A session mentions /hook and capture-terminal.sh"
            .write(to: history, atomically: true, encoding: .utf8)
        var status = try #require(EnvironmentDetector.detect([spec]).first)
        #expect(status.configured)
        #expect(!status.hookInjected)

        let hooks = URL(fileURLWithPath: try #require(spec.hookPath))
        try FileManager.default.createDirectory(at: hooks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "vibebuddy-forward.sh".write(to: hooks, atomically: true, encoding: .utf8)
        status = try #require(EnvironmentDetector.detect([spec]).first)
        #expect(status.hookInjected)

        try FileManager.default.removeItem(at: hooks)
        status = try #require(EnvironmentDetector.detect([spec]).first)
        #expect(!status.hookInjected)
    }

    @Test("the default CLI list mirrors the universal installer's set")
    func defaults() {
        let names = Set(EnvironmentDetector.defaultCLIs(home: "/h").map(\.name))
        #expect(names == ["claude", "codex", "grok", "antigravity", "opencode", "cursor"])
    }

    /// Cursor keeps its lifecycle hooks in one user-level file beside its home
    /// directory, so "configured" and "wired" are two different paths.
    @Test("Cursor is detected by its home directory and wired in hooks.json")
    func cursor() throws {
        let dir = tempDir()
        let cursorHome = dir.appendingPathComponent(".cursor")
        try FileManager.default.createDirectory(at: cursorHome, withIntermediateDirectories: true)
        let spec = CLISpec(name: "cursor", configPath: cursorHome.path,
                           hookPath: cursorHome.appendingPathComponent("hooks.json").path)
        var status = try #require(EnvironmentDetector.detect([spec]).first)
        #expect(status.configured)
        #expect(!status.hookInjected)

        try #"{"version":1,"hooks":{"stop":[{"command":"…/cursor-followup.sh"}],"#
            .appending(#""preToolUse":[{"command":"…/approval-hook.sh cursor"}]}}"#)
            .write(to: cursorHome.appendingPathComponent("hooks.json"), atomically: true, encoding: .utf8)
        status = try #require(EnvironmentDetector.detect([spec]).first)
        #expect(status.hookInjected)
    }

    @Test("the early inline-curl marker: the installer's exact command at any port, never a user's local webhook")
    func inlineCurlAnyPort() {
        for text in ["curl -sS --max-time 3 -X POST --data-binary @- http://127.0.0.1:9877/hook 2>/dev/null || true",
                     "curl 127.0.0.1:9876/hook"] {
            #expect(EnvironmentDetector.containsInlineCurlHook(text), "\(text)")
        }
        for text in ["curl -s -X POST http://127.0.0.1:3000/hook -d @-", "curl http://127.0.0.1:8080/hook.php",
                     "curl 127.0.0.1:5000/hook#a", "curl 127.0.0.1/hook", "/Users/me/hooks/thing.sh"] {
            #expect(!EnvironmentDetector.containsInlineCurlHook(text), "\(text)")
        }
    }
}
