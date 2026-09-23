import Foundation
import OSLog
import VibeBuddyKit
import VibeBuddyMacCore

/// Onboarding / setup model (issues 05 + 06): reports which agent CLIs are
/// configured and whether the vibebuddy hook is injected (`EnvironmentDetector`,
/// read-only), and drives install/uninstall through the native
/// `HookInstaller` — no python3, so a stranger's Mac can be wired from here.
/// Every operation runs off the main thread.
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
        let e2eHome = E2ERunConfiguration.current?.file("agents").path
        let home = e2eHome ?? NSHomeDirectory()
        // An isolated acceptance run must not follow the user's overrides.
        let environment = e2eHome == nil ? ProcessInfo.processInfo.environment : [:]
        refreshTask = Task { [weak self] in
            while self?.refreshPending == true {
                self?.refreshPending = false
                guard let generation = self?.refreshGeneration else { return }
                let statuses = await Task.detached(priority: .userInitiated) {
                    EnvironmentDetector.detect(EnvironmentDetector.defaultCLIs(home: home, environment: environment))
                }.value
                if let self, !self.running && generation == self.refreshGeneration { self.statuses = statuses }
            }
            self?.refreshTask = nil
        }
    }

    /// True when at least one CLI is configured but missing the vibebuddy hook,
    /// or has its status line unwired — for Claude that forwarder is the only
    /// source of account quota, so a missing one is as broken as a missing hook.
    var hasUnwiredCLI: Bool {
        statuses.contains { $0.configured && (!$0.hookInjected || $0.statusLineWired == false) }
    }

    /// Every detected CLI; keeps any approval gate the user opted into.
    func install() { run(checkCodexTrust: true) { $0.install() } }

    /// Removes vibebuddy from every CLI and remembers it, so launches and
    /// updates never put the hooks back.
    func uninstall() { run(checkCodexTrust: false) { $0.uninstall() } }

    /// Targeted repair is only reached from an explicit per-agent Settings
    /// button. Idempotent; foreign hook entries are preserved.
    func repair(_ agent: AgentKind) {
        guard let target = HookAgent(agent) else { return }
        run(checkCodexTrust: target == .codex) { $0.install([target], approval: target == .cursor) }
    }

    func enableStatusLine() {
        run(checkCodexTrust: false) { $0.enableStatusLine() }
    }

    /// The installer reading the runtime scripts from
    /// `Contents/Resources/hooks/` and copying them to the stable
    /// `~/Library/Application Support/vibebuddy/bin/` every config names.
    nonisolated static func makeInstaller() -> HookInstaller {
        HookInstaller(environment: .live(),
                      scriptSource: Bundle.main.resourceURL?.appendingPathComponent("hooks", isDirectory: true))
    }

    /// App launch: re-copy the scripts after an update, but only for hooks the
    /// user has installed and not explicitly removed. Never edits a config.
    nonisolated static func refreshScriptsOnLaunch() {
        guard E2ERunConfiguration.current == nil else { return }
        Task.detached(priority: .utility) {
            if let note = makeInstaller().refreshOnLaunch() {
                Logger(subsystem: "com.vibebuddy.app", category: "hooks").notice("\(note, privacy: .public)")
            }
        }
    }

    private func run(checkCodexTrust: Bool,
                     _ operation: @escaping @Sendable (HookInstaller) -> HookInstallReport) {
        guard E2ERunConfiguration.current == nil else {
            lastOutput = "Hook installation is disabled during isolated acceptance."
            return
        }
        guard !running else { return }
        refreshGeneration += 1
        refreshPending = false
        running = true
        Task.detached(priority: .userInitiated) {
            let installer = Self.makeInstaller()
            let report = operation(installer)
            var lines = [report.text]
            // Written into hooks.json is not the same as run: ask Codex.
            if checkCodexTrust, report.touched.contains(.codex) {
                let verdict = await CodexHookTrustProbe.check(
                    socketPath: installer.paths.codexControlSocket.path, timeout: .seconds(3))
                lines.append(CodexHookTrustProbe.lines(for: verdict).joined(separator: "\n"))
            }
            if report.failures > 0 { lines.append("\(report.failures) failure(s).") }
            let output = lines.joined(separator: "\n\n")
            await MainActor.run {
                self.lastOutput = output
                self.running = false
                self.refresh()
            }
        }
    }
}
