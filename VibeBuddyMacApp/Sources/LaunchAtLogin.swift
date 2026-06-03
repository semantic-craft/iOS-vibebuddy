import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). Requires a real .app bundle —
/// which is exactly why the menu-bar app is now an Xcode app, not a SwiftPM CLI.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            FileHandle.standardError.write(Data("launch-at-login error: \(error)\n".utf8))
        }
    }
}
