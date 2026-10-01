import XCTest

/// Runs the changed phone screens against an isolated Mac. No production pairing,
/// cloud runner, real key typing or unbounded full-app crawl.
final class IOSParityE2E: XCTestCase {
    private func button(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, labels)).firstMatch
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            // Keep the gesture inside the visible form when the keyboard covers
            // the bottom of the screen (especially at accessibility sizes).
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)))
        }
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testRealTaskDetailsAndHistoryFallback() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["VIBEBUDDY_QA_TOKEN"], let port = env["VIBEBUDDY_QA_PORT"], port != "9876" else { throw XCTSkip("Requires isolated companion") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.vibebuddy.app")
        app.launchEnvironment = ["VIBEBUDDY_HOST": "127.0.0.1", "VIBEBUDDY_PORT": port, "VIBEBUDDY_TOKEN": token]
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["phone-inbox-connection"].waitForExistence(timeout: 10))
        let id = try XCTUnwrap(env["VIBEBUDDY_QA_SESSION"])
        var link = URLComponents(string: "vibebuddy://session")!
        link.queryItems = [URLQueryItem(name: "id", value: id)]
        app.open(try XCTUnwrap(link.url))
        let details = button(app, ["任务目标与后台终端", "Task goal and background terminals"])
        XCTAssertTrue(details.waitForExistence(timeout: 5)); details.tap()
        XCTAssertTrue(app.staticTexts["Codex 服务未连接。"].firstMatch.waitForExistence(timeout: 5))
        capture(app, "task-details-unavailable")
        let history = app.buttons["phone-open-history"]
        reveal(history, in: app); history.tap()
        XCTAssertTrue(app.staticTexts["Codex 服务历史不可用 · 已改用本地记录或近期片段。"].waitForExistence(timeout: 5))
        let message = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "phone-history-message-")).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 5))
        capture(app, "real-history-fallback")
        app.terminate()
    }
    func testChangedSettingsInChineseAndLargeType() throws {
        let env = ProcessInfo.processInfo.environment
        guard let token = env["VIBEBUDDY_QA_TOKEN"], let port = env["VIBEBUDDY_QA_PORT"], port != "9876" else {
            throw XCTSkip("Requires isolated companion")
        }
        continueAfterFailure = false
        for large in [false, true] {
            let app = XCUIApplication(bundleIdentifier: "com.vibebuddy.app")
            app.launchEnvironment = ["VIBEBUDDY_HOST": "127.0.0.1", "VIBEBUDDY_PORT": port, "VIBEBUDDY_TOKEN": token]
            app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "-phone.readAloud.selection", "minimax"]
            if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
            app.launch()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deny = button(springboard, ["Don’t Allow", "Don't Allow", "不允许"])
            if deny.waitForExistence(timeout: 2) { deny.tap() }
            let settings = button(app, ["Settings", "设置"])
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            let started = Date(); settings.tap()
            let speech = button(app, ["Summary & speech", "摘要与朗读", "摘要与语音", "摘要与播报"])
            if !speech.waitForExistence(timeout: 3) {
                let tree = XCTAttachment(string: app.debugDescription); tree.name="settings-tree"; add(tree)
            }
            XCTAssertTrue(speech.exists)
            speech.tap()
            let language = app.buttons["phone-reading-language"]
            reveal(language, in: app)
            XCTAssertTrue(language.waitForExistence(timeout: 4))
            print("IOS_PARITY_UI settings_seconds=\(Date().timeIntervalSince(started)) large=\(large)")
            reveal(language, in: app)
            XCTAssertTrue(language.isHittable)
            capture(app, large ? "speech-zh-AXXXL" : "speech-zh-default")
            language.tap()
            let chinese = button(app, ["简体中文"])
            XCTAssertTrue(chinese.waitForExistence(timeout: 2)); chinese.tap()
            let service = button(app, ["Service settings", "服务设置"])
            reveal(service, in: app); XCTAssertTrue(service.isHittable); service.tap()
            let draft = app.secureTextFields["phone-api-key-draft"]
            reveal(draft, in: app); XCTAssertTrue(draft.waitForExistence(timeout: 2))
            draft.tap(); draft.typeText("e2e-draft-not-a-real-key")
            let cancel = button(app, ["Cancel key edit", "取消密钥编辑"])
            reveal(cancel, in: app); XCTAssertTrue(cancel.isHittable); cancel.tap()
            capture(app, large ? "cancel-keyboard-AXXXL" : "cancel-keyboard-default")
            let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 3), .completed)
            let save = app.buttons["phone-save-api-key"]
            for _ in 0..<8 where !save.exists { app.swipeDown() }
            XCTAssertTrue(save.exists)
            XCTAssertFalse(save.isEnabled)
            capture(app, large ? "credential-draft-AXXXL" : "credential-draft-default")
            app.terminate()
        }
    }
}
