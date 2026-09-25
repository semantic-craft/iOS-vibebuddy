import XCTest

/// AX_OUT = output dir, AX_SIZE = content size category name (optional), AX_PAGES = comma list of VIBEBUDDY_DEMO_PAGE values ("home" = none).
final class PhoneAudit: XCTestCase {
    func testAudit() throws {
        let env = ProcessInfo.processInfo.environment
        let out = env["AX_OUT"]!
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let pages = (env["AX_PAGES"] ?? "home").split(separator: ",").map(String.init)
        for page in pages {
            let app = XCUIApplication(bundleIdentifier: "com.vibebuddy.app")
            app.launchEnvironment = ["VIBEBUDDY_DEMO": "1"]
            if page != "home" { app.launchEnvironment["VIBEBUDDY_DEMO_PAGE"] = page }
            if let size = env["AX_SIZE"], !size.isEmpty { app.launchArguments = ["-UIPreferredContentSizeCategoryName", size] }
            if env["AX_REDUCE_MOTION"] == "1" { app.launchArguments += ["-UIAccessibilityReduceMotionEnabled", "YES"] }
            app.launch()
            sleep(3)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for title in ["Allow", "允许"] where springboard.buttons[title].waitForExistence(timeout: 1) {
                springboard.buttons[title].tap()
            }
            sleep(2)
            Audit.run(app, screen: page.replacingOccurrences(of: "/", with: "_"), out: out, test: self)
            app.terminate()
        }
    }
}
