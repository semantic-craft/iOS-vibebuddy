import Foundation
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

    func refresh() {
        statuses = EnvironmentDetector.detect(EnvironmentDetector.defaultCLIs())
    }

    /// True when at least one CLI is configured but missing the vibebuddy hook.
    var hasUnwiredCLI: Bool { statuses.contains { $0.configured && !$0.hookInjected } }

    func install() { run("--install") }
    func uninstall() { run("--uninstall") }

    /// Locate the installer bundled at `Contents/Resources/hooks/`.
    private static func scriptURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("hooks/install-agent-hooks.py")
    }

    private func run(_ mode: String) {
        guard !running, let script = Self.scriptURL(),
              FileManager.default.fileExists(atPath: script.path) else {
            lastOutput = "Installer not found in the app bundle."
            return
        }
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
