import Foundation

enum AppRelaunch {
    /// Wait for normal termination (including agent shutdown and the instance
    /// lock release). A fixed delay can reopen too early and lose the restart.
    static func schedule() throws {
        UserDefaults.standard.synchronize()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        var arguments = ["-c", """
            pid="$1"
            shift
            while kill -0 "$pid" 2>/dev/null; do
                /bin/sleep 0.1
            done
            exec /usr/bin/open "$@"
            """, "vibebuddy-relaunch", String(ProcessInfo.processInfo.processIdentifier),
            "-n"]
        // Preserve isolation when the same user flow is exercised by an E2E
        // bundle; Launch Services does not inherit the caller's environment.
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key })
            where key.hasPrefix("VIBEBUDDY_E2E_") || key == "VIBEBUDDY_DEMO_PAGE" || key == "VIBEBUDDY_DEMO" {
            arguments += ["--env", "\(key)=\(value)"]
        }
        arguments.append(Bundle.main.bundleURL.path)
        helper.arguments = arguments
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
}
