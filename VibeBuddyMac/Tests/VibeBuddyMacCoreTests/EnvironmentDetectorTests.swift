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

    @Test("a plugin dir is scanned recursively for the marker")
    func dirScan() throws {
        let dir = tempDir()
        let plugin = dir.appendingPathComponent("opencode/plugin")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try "// uses capture-terminal.sh\n"
            .write(to: plugin.appendingPathComponent("vibebuddy.js"), atomically: true, encoding: .utf8)
        let status = EnvironmentDetector.detect([CLISpec(name: "opencode", configPath: dir.appendingPathComponent("opencode").path)]).first!
        #expect(status.configured)
        #expect(status.hookInjected)
    }

    @Test("the default CLI list mirrors the universal installer's set")
    func defaults() {
        let names = Set(EnvironmentDetector.defaultCLIs(home: "/h").map(\.name))
        #expect(names == ["claude", "codex", "qwen", "grok", "antigravity", "kimi", "opencode"])
    }
}
