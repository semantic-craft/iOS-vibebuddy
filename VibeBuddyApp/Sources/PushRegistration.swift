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

    /// Re-report current sound prefs to the Mac (call when the user changes them),
    /// so the Mac's background push respects play-sound / quiet mode.
    func reportPrefs() { upload() }

    private func upload() {
        guard let token = deviceToken, let pairing,
              let url = URL(string: "http://\(pairing.host):\(pairing.port)/device")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(DeviceRegistrationPayload(
            token: token,
            name: UIDevice.current.name,
            model: UIDevice.current.model,
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            playSound: SoundPrefs.playSound,
            quietMode: SoundPrefs.effectiveQuiet(),
            categories: SoundPrefs.categories
        ))
        Task { _ = try? await URLSession.shared.data(for: request) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Present our cues while the app is foreground — otherwise iOS swallows
        // the sound, and the in-app sound pack would never be heard.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistration.shared.didReceive(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No paid account / entitlement yet — expected until APNs is set up.
    }

    /// A tapped banner opens its session. Both channels name the session the
    /// same way — the local notification's `userInfo["sessionId"]` and the Mac
    /// push's top-level `sessionId` — and both go through the Live Activity's
    /// deep link, which focuses the row and acknowledges the completion. That
    /// acknowledgement is what stops a followed session's reminders.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let id = response.notification.request.content.userInfo["sessionId"] as? String,
              !id.isEmpty else { return }
        await MainActor.run {
            _ = UIApplication.shared.open(VibeBuddyDeepLink.sessionURL(id: id))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // A remote push that arrives while the app is foreground is redundant:
        // the live stream + local SoundPolicy already handle it (and completion
        // is meant to be silent when you're watching). Suppress to avoid a
        // double sound; backgrounded pushes are unaffected (willPresent isn't called).
        if notification.request.trigger is UNPushNotificationTrigger { return [] }
        // Pairing confirmation: a sound is enough — the dashboard is already up.
        if notification.request.identifier == NotificationID.pairSuccess { return [.sound] }
        return [.banner, .sound, .list]
    }
}
