import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// Onboarding / setup model (issues 05 + 06): reports which agent CLIs are
/// configured and whether the vibebuddy hook is injected (`EnvironmentDetector`,
/// read-only), and drives install/uninstall by shelling out to the **bundled,
/// already-tested** Python installers (`hooks/install-agent-hooks.py`) rather than
/// reimplementing injection in Swift (ADR-less decision recorded in
/// `.scratch/mac-power-features/issues/06`).
@MainActor
final class HookSetup: ObservableObject {
    @Published private(set) var statuses: [CLIHookStatus] = []
    @Published private(set) var lastOutput: String = ""
    @Published private(set) var running = false

    private var refreshTask: Task<Void, Never>?

    private var refreshPending = false
    private var refreshGeneration = 0

    func refresh() {
        guard !running else { return }
        refreshGeneration += 1
        refreshPending = true
        guard refreshTask == nil else { return }
        let home = E2ERunConfiguration.current?.file("agents").path ?? NSHomeDirectory()
        refreshTask = Task { [weak self] in
            while self?.refreshPending == true {
                self?.refreshPending = false
                guard let generation = self?.refreshGeneration else { return }
                let statuses = await Task.detached(priority: .userInitiated) {
                    EnvironmentDetector.detect(EnvironmentDetector.defaultCLIs(home: home))
                }.value
                if let self, !self.running && generation == self.refreshGeneration { self.statuses = statuses }
            }
            self?.refreshTask = nil
        }
    }

    /// True when at least one CLI is configured but missing the vibebuddy hook.
    var hasUnwiredCLI: Bool { statuses.contains { $0.configured && !$0.hookInjected } }

    func install() { run("--install") }
    func uninstall() { run("--uninstall") }

    /// Targeted repair is only reached from an explicit per-agent Settings
    /// button. Both installers are idempotent and preserve foreign hook entries.
    func repair(_ agent: AgentKind) {
        switch agent {
        case .claudeCode: run("--install", scriptName: "install-claude-hooks.py")
        case .codex: run("--install", scriptName: "install-codex-hooks.py")
        case .grok: run("--install", scriptName: "install-grok-hooks.py")
        case .cursor: run("--approval", scriptName: "install-cursor-hooks.py")
        default: break
        }
    }

    func enableStatusLine() {
        run("--statusline", scriptName: "install-claude-hooks.py")
    }

    /// Locate the installer bundled at `Contents/Resources/hooks/`.
    private static func scriptURL(named name: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("hooks/\(name)")
    }

    private func run(_ mode: String, scriptName: String = "install-agent-hooks.py") {
        guard E2ERunConfiguration.current == nil else {
            lastOutput = "Hook installation is disabled during isolated acceptance."
            return
        }
        guard !running, let script = Self.scriptURL(named: scriptName),
              FileManager.default.fileExists(atPath: script.path) else {
            lastOutput = "Installer not found in the app bundle."
            return
        }
        refreshGeneration += 1
        refreshPending = false
        running = true
        Task.detached(priority: .userInitiated) {
            let output = Self.shell(script: script.path, mode: mode)
            await MainActor.run {
                self.lastOutput = output
                self.running = false
                self.refresh()
            }
        }
    }

    nonisolated private static func shell(script: String, mode: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script, mode]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "Failed to launch installer: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
