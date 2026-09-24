import Foundation
import VibeBuddyMacCore

/// `vibebuddyd hooks …`: install, remove or inspect vibebuddy's agent hooks
/// without the menu-bar app and without python3.
enum HooksCommand {
    static let usage = """
    Usage:
      vibebuddyd hooks install   [--agent NAME]... [--approval] [--statusline] [--hooks-dir DIR]
      vibebuddyd hooks uninstall [--agent NAME]...
      vibebuddyd hooks status

      --agent NAME   claude, codex, cursor, grok, opencode or antigravity (repeatable,
                     or comma-separated). Default: install into every configured CLI;
                     uninstall from all of them.
      --approval     add the blocking phone-approval gate (Claude, Codex, Grok, Cursor).
      --statusline   the status line only (Claude's by default, Grok's with --agent grok);
                     no hooks are touched.
      --hooks-dir    where the runtime scripts are (default: VIBEBUDDY_HOOKS_DIR, then this
                     binary's own app bundle or checkout, then /Applications/VibeBuddyMacApp.app).
                     They are copied to ~/Library/Application Support/vibebuddy/bin/,
                     the one path every config names.

    """

    static func run(_ arguments: [String]) async -> Int32 {
        guard let action = arguments.first, ["install", "uninstall", "status"].contains(action) else {
            FileHandle.standardError.write(Data(usage.utf8))
            return EXIT_FAILURE
        }
        var agents: [HookAgent] = []
        var approval = false
        var statusLine = false
        var hooksDirectory: String?
        var rest = arguments.dropFirst().makeIterator()
        while let argument = rest.next() {
            switch argument {
            case "--agent":
                guard let value = rest.next() else { return fail("--agent needs a name") }
                for name in value.split(separator: ",").map(String.init) {
                    guard let agent = HookAgent(rawValue: name) else { return fail("unknown agent: \(name)") }
                    if !agents.contains(agent) { agents.append(agent) }
                }
            case "--approval": approval = true
            case "--statusline": statusLine = true
            case "--hooks-dir":
                guard let value = rest.next() else { return fail("--hooks-dir needs a directory") }
                hooksDirectory = value
            default: return fail("unknown option: \(argument)")
            }
        }
        if action != "status", geteuid() == 0 {
            return fail("refusing to run as root: it would write root's agent configs and leave root-owned files in yours. Run it as your own user.")
        }
        let source = HookScriptSource.locate(explicit: hooksDirectory)
        if hooksDirectory != nil && source == nil {
            return fail("\(hooksDirectory!) does not contain the hook scripts")
        }
        let installer = HookInstaller(environment: .live(), scriptSource: source)
        if action == "install" {
            print("hook scripts from: \(source?.path ?? "(none found; using the existing \(installer.paths.bin.path))")")
            if let source, let app = HookScriptSource.differingInstalledApp(source) {
                print("note: these differ from the installed app's scripts (\(app.path)); every agent on this Mac runs them until the app next launches and restores its own")
            }
        }
        switch action {
        case "status":
            for status in installer.status() { print(status.summary) }
            print("stable scripts: \(installer.paths.bin.path)")
            print(CodexHookTrustProbe.lines(for: await CodexHookTrustProbe.check(socketPath: installer.paths.codexControlSocket.path, timeout: .seconds(3)))
                .joined(separator: "\n"))
            return EXIT_SUCCESS
        case "uninstall":
            let report = installer.uninstall(agents.isEmpty ? nil : agents)
            print(report.text)
            return report.failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE
        default:
            let report: HookInstallReport
            if statusLine {
                guard agents.count <= 1 else { return fail("--statusline takes one --agent (claude or grok)") }
                report = installer.enableStatusLine(agents.first ?? .claude)
            } else {
                report = installer.install(agents.isEmpty ? nil : agents, approval: approval)
            }
            print(report.text)
            if report.touched.contains(.codex), !statusLine {
                print("")
                print(CodexHookTrustProbe.lines(for: await CodexHookTrustProbe.check(socketPath: installer.paths.codexControlSocket.path, timeout: .seconds(3)))
                    .joined(separator: "\n"))
            }
            return report.failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE
        }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("vibebuddyd hooks: \(message)\n\n\(usage)".utf8))
        return EXIT_FAILURE
    }
}
