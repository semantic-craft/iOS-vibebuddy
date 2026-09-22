import UIKit
import UserNotifications
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
    private(set) var pairing: PairingPayload?

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

    /// Background actions can arrive before any dashboard view has loaded.
    func pairingForBannerAction() -> PairingPayload? {
        if let pairing { return pairing }
        return ConnectionStore().pairing
    }

    /// Re-report this device to the Mac: on a preference change, and on every
    /// dashboard (re)connection. The Mac's registry can have been emptied by a
    /// restart while this app never relaunched, and this is what repairs it.
    func reportPrefs() { upload() }

    /// Tell the Mac what this phone did about some cues itself: `posted` lets it
    /// drop the push it may be holding for them; `coveredByPush` names waiting
    /// cues left to a push that had already landed (ADR-0012). Keyed by the
    /// APNs token because that is the name the Mac pushes to; with no token
    /// there is no push to stand down, so nothing is sent.
    func report(posted: [NotifiedPayload.Cue] = [], coveredByPush: [NotifiedPayload.Cue] = []) async {
        guard let token = deviceToken, let pairing, !(posted.isEmpty && coveredByPush.isEmpty),
              let url = pairing.companionURL(path: "notified") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(NotifiedPayload(
            token: token, posted: posted, coveredByPush: coveredByPush))
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The single `POST /device` path. The APNs token is included once it is
    /// known and omitted before that, so an un-entitled build still reports its
    /// name for the Mac's "Paired: <name>" display.
    private func upload() {
        guard let pairing,
              let url = pairing.companionURL(path: "device")
        else { return }
        let token = deviceToken
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var registration = DeviceRegistrationPayload(
            token: token,
            // A retained Keychain identity lets a rotated token replace this
            // phone's existing record on the Mac.
            deviceID: PushDeviceIdentity.current(),
            name: UIDevice.current.name,
            model: UIDevice.current.model,
            systemVersion: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            playSound: SoundPrefs.playSound,
            quietMode: SoundPrefs.effectiveQuiet(),
            categories: SoundPrefs.categories)
        registration.supportsCompletionNotices = true
        request.httpBody = try? JSONEncoder().encode(registration)
        Task { _ = try? await URLSession.shared.data(for: request) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Present our cues while the app is foreground — otherwise iOS swallows
        // the sound, and the in-app sound pack would never be heard.
        UNUserNotificationCenter.current().delegate = self
        LocalNotifier.registerCategories()
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

    /// The Mac's waiting cues carry `content-available` (ADR-0032). iOS grants
    /// this wake at its own discretion and never to a force-quit app.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let payload = userInfo.reduce(into: [String: String]()) { partial, entry in
            if let key = entry.key as? String, let value = entry.value as? String { partial[key] = value }
        }
        let category = (userInfo["aps"] as? [AnyHashable: Any])?["category"] as? String
        Task {
            var info: [AnyHashable: Any] = payload
            if let category { info["aps"] = ["category": category] }
            let result = await handleBackgroundPush(userInfo: info)
            await MainActor.run { completionHandler(result) }
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        Task { await PushCoverage.shared.noteActivated() }
    }

    /// A tapped banner opens its session. Both channels name the session the
    /// same way — the local notification's `userInfo["sessionId"]` and the Mac
    /// push's top-level `sessionId` — and both go through the Live Activity's
    /// deep link, which focuses the row and acknowledges the completion. That
    /// acknowledgement is what stops a followed session's reminders.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let request = response.notification.request
        let actionIdentifier = response.actionIdentifier
        let identifier = request.identifier
        let isRemote = request.trigger is UNPushNotificationTrigger
        let deliveredAt = response.notification.date
        let text = (response as? UNTextInputNotificationResponse)?.userText
        // Only these string fields are consumed by notification routing/actions.
        // Snapshot them before leaving the delegate's isolation context.
        let userInfo = [
            NotificationUserInfoKey.sessionId: request.content.userInfo[NotificationUserInfoKey.sessionId] as? String,
            NotificationUserInfoKey.approvalId: request.content.userInfo[NotificationUserInfoKey.approvalId] as? String,
            NotificationUserInfoKey.questionId: request.content.userInfo[NotificationUserInfoKey.questionId] as? String
        ].compactMapValues { $0 }
        // The async delegate bridge can finish on a cooperative executor. UIKit's
        // notification-response completion restores scene state and requires main.
        Task {
            await handleNotificationResponse(actionIdentifier: actionIdentifier, identifier: identifier,
                isRemote: isRemote, deliveredAt: deliveredAt, userInfo: userInfo, text: text)
            await MainActor.run { completionHandler() }
        }
    }

    nonisolated private func handleNotificationResponse(
        actionIdentifier: String, identifier: String, isRemote: Bool, deliveredAt: Date,
        userInfo: [String: String], text: String?
    ) async {
        // A tapped push leaves Notification Center; remember it so the stream's
        // catch-up does not announce the same wait a second time (ADR-0012).
        // Content-free evidence of which device receives the default tap.
        if let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
           let data = try? JSONSerialization.data(withJSONObject: [
                "timestamp": Date().timeIntervalSince1970,
                "defaultTap": actionIdentifier == UNNotificationDefaultActionIdentifier
           ]) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("phone-notification-tap.json"), options: .atomic)
        }
        if isRemote {
            await PushCoverage.shared.noteTapped(identifier: identifier,
                                                 deliveredAt: deliveredAt)
        }
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            guard let id = userInfo[NotificationUserInfoKey.sessionId], !id.isEmpty else { return }
            let completionID = NotificationIdentity.sound(of: identifier) == .agentDone
                ? identifier : nil
            await MainActor.run {
                _ = UIApplication.shared.open(VibeBuddyDeepLink.sessionURL(id: id,
                    completionNotificationID: completionID))
            }
            return
        }
        let pairing = await MainActor.run { PushRegistration.shared.pairingForBannerAction() }
        let epoch = await MainActor.run { ConnectionStore.pairingEpoch }
        // A tap the Mac cannot be given is held under its own key and
        // reported through a notification of its own — the tap was made on
        // the wrist or the lock screen, where opening the app is no answer
        // (ADR-0032). The queue's listener (the dashboard store) posts it.
        let outcome = await BannerActionRunner.perform(
            actionIdentifier: actionIdentifier,
            userInfo: userInfo,
            text: text,
            pairing: pairing,
            client: HTTPDecisionClient(),
            epoch: epoch,
            hold: { action, reason in
                // Saved and reported before this returns: iOS may suspend the
                // process the moment the completion handler runs, and an
                // unfinished hold would be the silent drop all over again.
                await MainActor.run { PendingActionStore.shared.hold(action, reason: reason) }
            })
        let macName = pairing?.macName
        switch outcome {
        case .openSession(let id):
            await MainActor.run {
                _ = UIApplication.shared.open(VibeBuddyDeepLink.sessionURL(id: id))
            }
        case .held:
            await LocalNotifier.settle()
        case .notHeld(let action):
            // Nothing applied, decide again — under its own identifier, so
            // the live "on hold" banner of the earlier decision stays up.
            LocalNotifier().warnNotHeld(action, macName: macName)
            await LocalNotifier.settle()
        case .unconfirmed(let action):
            LocalNotifier().warnUnconfirmed(action, macName: macName)
            await LocalNotifier.settle()
        case .ignored:
            break
        }
    }

    /// A waiting cue's push woke the app (`content-available`). Ask the Mac
    /// whether this phone can reach it right now: deliver what is held if
    /// so, and if not, say which link is missing — before the person taps
    /// Approve on a card that cannot be answered (ADR-0032).
    nonisolated func handleBackgroundPush(userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let category = (userInfo["aps"] as? [AnyHashable: Any])?["category"] as? String
        guard category != nil else { return .noData }
        let pairing = await MainActor.run { PushRegistration.shared.pairingForBannerAction() }
        guard let pairing else { return .noData }
        let client = HTTPDecisionClient()
        switch await client.probe(pairing) {
        case .reachable:
            let epoch = await MainActor.run { ConnectionStore.pairingEpoch }
            await PendingActionStore.shared.flush(pairing: pairing, epoch: epoch, client: client)
            // The "delivered" / "could not be confirmed" posts the flush
            // asked for must reach the system before this wake ends.
            await LocalNotifier.settle()
            return .newData
        case .unreachable(let reason):
            guard reason.isRetryable else { return .noData }
            LocalNotifier().warnUnreachable(reason, macName: pairing.macName)
            await LocalNotifier.settle()
            return .newData
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
