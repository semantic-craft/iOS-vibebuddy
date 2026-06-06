import Foundation
import Sparkle

/// Sparkle auto-update for the **directly-distributed** Mac app (issue 07; the
/// distribution decision was direct-download + Sparkle, not the Mac App Store).
///
/// Inert until `SUFeedURL` points at a real signed appcast and `SUPublicEDKey`
/// holds the Sparkle EdDSA public key (both placeholders in Info.plist for now);
/// automatic checks are off, so this only acts on an explicit "Check for Updates…".
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
