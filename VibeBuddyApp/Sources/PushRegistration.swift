import UIKit
import VibeBuddyKit

/// Registers for APNs, captures the device token, and uploads it to the Mac so
/// the Mac can push "needs you" alerts even when the app is closed.
///
/// Fully functional needs: a paid Apple Developer account, the aps-environment
/// entitlement (see VibeBuddyApp.entitlements), real signing, and an APNs key
/// (.p8) configured on the Mac. Until then registration just no-ops at runtime.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    private var deviceToken: String?
    private var pairing: PairingPayload?

    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    func didReceive(deviceToken data: Data) {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        upload()
    }

    func update(pairing: PairingPayload?) {
        self.pairing = pairing
        upload()
    }

    private func upload() {
        guard let token = deviceToken, let pairing,
              let url = URL(string: "http://\(pairing.host):\(pairing.port)/device")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(token.utf8)
        Task { _ = try? await URLSession.shared.data(for: request) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.didReceive(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No paid account / entitlement yet — expected until APNs is set up.
    }
}
