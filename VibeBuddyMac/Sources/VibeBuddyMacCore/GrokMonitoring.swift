import Foundation
import VibeBuddyKit

/// Stored intent is independent of account usage. Existing hook installs migrate
/// as enabled; an explicit uninstall always wins over legacy installation data.
public struct GrokMonitoringConfiguration: Sendable, Equatable {
    public var enabled: Bool
    public var configured: Bool
    public var available: Bool
    public var error: String?

    public init(enabled: Bool, configured: Bool, available: Bool = true, error: String? = nil) {
        self.enabled = enabled
        self.configured = configured
        self.available = available
        self.error = error
    }
}

extension HookInstaller {
    public var grokMonitoringConfiguration: GrokMonitoringConfiguration {
        let state = files.loadState()
        let key = paths.entryKey(.grok)
        let grok = GrokHooks(paths: paths, context: context(manifest: files.loadManifest()))
        let commands = (try? grok.ourCommands()) ?? []
        let configured = grok.observationHooksConfigured
        let enabled = !state.uninstalled.contains(key)
            && (state.grokMonitoring?[key] ?? (!commands.isEmpty || files.loadManifest().agents[key] != nil))
        return .init(enabled: enabled, configured: configured,
                     available: files.exists(paths.grokDirectory), error: state.grokMonitoringErrors?[key])
    }

    /// Save intent before touching hooks, so disabling still gates incoming
    /// events when a CLI config cannot be edited. A failed install is retryable.
    public func setGrokMonitoring(_ enabled: Bool) -> HookInstallReport {
        var state = files.loadState()
        let key = paths.entryKey(.grok)
        state.grokMonitoring = (state.grokMonitoring ?? [:]).merging([key: enabled]) { _, new in new }
        state.grokMonitoringErrors?[key] = nil
        if enabled { state.uninstalled.removeAll { $0 == key } }
        do { try files.saveState(state) }
        catch { return .init(lines: [String(describing: error)], failures: 1) }
        var report: HookInstallReport
        if enabled && !files.exists(paths.grokDirectory) {
            report = .init(lines: ["Grok Build was not found. Open Grok Build once, then retry."], failures: 1)
        } else {
            report = enabled ? install([.grok]) : uninstall([.grok])
        }
        state = files.loadState()
        if report.failures > 0 {
            state.grokMonitoringErrors = (state.grokMonitoringErrors ?? [:]).merging([key: report.text]) { _, new in new }
        } else { state.grokMonitoringErrors?[key] = nil }
        do { try files.saveState(state) }
        catch { report.failures += 1; report.lines.append(String(describing: error)) }
        return report
    }
}
