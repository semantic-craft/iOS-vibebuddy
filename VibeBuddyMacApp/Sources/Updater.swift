import Foundation
import Sparkle

/// Sparkle auto-update for the **directly-distributed** Mac app (issue 07; the
/// distribution decision was direct-download + Sparkle, not the Mac App Store).
///
/// `SUFeedURL` and `SUPublicEDKey` are live as of 1.1 (see docs/sparkle-setup.md);
/// the feed and the signed DMG are produced by tools/release-mac.sh. Info.plist sets
/// no `SUEnableAutomaticChecks`, so Sparkle asks the user once whether to check on
/// its own; "Check for Updates…" works either way.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
}
