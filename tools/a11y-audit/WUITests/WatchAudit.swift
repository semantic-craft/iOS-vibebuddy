import XCTest

/// AX_OUT, AX_SIZE, AX_SCREENS = comma list of scenario:page[:task].
final class WatchAudit: XCTestCase {
    func testAudit() throws {
        let env = ProcessInfo.processInfo.environment
        let out = env["AX_OUT"]!
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let screens = (env["AX_SCREENS"] ?? "normal:home").split(separator: ",").map(String.init)
        for screen in screens {
            let bits = screen.split(separator: ":").map(String.init)
            let app = XCUIApplication(bundleIdentifier: "com.vibebuddy.app.watchkitapp")
            app.launchEnvironment = ["VIBEBUDDY_DEMO": "1", "VIBEBUDDY_WATCH_SCENARIO": bits[0], "VIBEBUDDY_WATCH_PAGE": bits[1]]
            if bits.count > 2 { app.launchEnvironment["VIBEBUDDY_WATCH_TASK"] = bits[2] }
            if let size = env["AX_SIZE"], !size.isEmpty { app.launchArguments = ["-UIPreferredContentSizeCategoryName", size] }
            app.launch()
            sleep(4)
            Audit.run(app, screen: screen.replacingOccurrences(of: ":", with: "_"), out: out, test: self)
            app.terminate()
        }
    }
}
