import Foundation
import UserNotifications
import VibeBuddyKit
import WatchKit

/// Where a tapped notification lands, and what its buttons do.
///
/// Notifications are mirrored from the iPhone. Apple runs a *foreground*
/// action on the device where it was tapped and a *background* action on the
/// device the notification was sent to — the iPhone, always, for anything the
/// wrist sees. Every action the iPhone registers is a foreground action
/// (ADR-0033), so a tap on Approve here launches this app and arrives in this
/// delegate, where it is mapped (`WatchNotificationResponseRoute`) onto the
/// same `WatchSessionActionRequest` path the card's own buttons use. The
/// outcome — sent, taken, failed — is shown on the card that opens, with a
/// tap, exactly as a card-initiated action is. A background action would have
/// run on a phone in a pocket, out of sight, and its failure would have been
/// invisible from the wrist: that was the shape of the 2026-09-22 rounds in
/// which Approve on the banner never reached the Mac.
///
/// The default tap opens the session the buzz was about; without a delegate it
/// would open on whatever the home screen happens to lead with, which is fine
/// with one thing waiting and wrong with three.
///
/// The delegate is registered at launch, before any scene exists, and the
/// store may not exist yet either (a cold launch from a notification). So the
/// router holds the route until the main window is active. The window
/// refreshes the relayed state before it lets the router present the target.
/// The app delegate exists for one reason: to be the notification centre's
/// delegate from the first moment of the process, which a SwiftUI scene cannot
/// promise.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Self.categories())
        Task { @MainActor in WatchNavigationDiagnostics.shared.record("delegate.ready") }
    }

    /// The same two categories the iPhone registers (`LocalNotifier.
    /// registerCategories`), with the same identifiers and the same foreground
    /// option. A mirrored notification draws the iPhone's actions; this
    /// registration is what an independent watchOS delivery would draw, and it
    /// must not disagree with the phone's about what a button means. On
    /// watchOS 27 the Reply below arrives without its words and opens the
    /// answer card instead (WR-09).
    static func categories() -> Set<UNNotificationCategory> {
        let approve = UNNotificationAction(
            identifier: NotificationActionID.approve.rawValue,
            title: String(localized: "Approve"),
            options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(
            identifier: NotificationActionID.deny.rawValue,
            title: String(localized: "Deny"),
            options: [.destructive, .foreground])
        let approval = UNNotificationCategory(
            identifier: NotificationCategoryID.approval.rawValue,
            actions: [approve, deny],
            intentIdentifiers: [])
        let reply = UNTextInputNotificationAction(
            identifier: NotificationActionID.answer.rawValue,
            title: String(localized: "Reply"),
            options: [.foreground],
            textInputButtonTitle: String(localized: "Send"),
            textInputPlaceholder: String(localized: "Answer"))
        let question = UNNotificationCategory(
            identifier: NotificationCategoryID.question.rawValue,
            actions: [reply],
            intentIdentifiers: [])
        return [approval, question]
    }

    /// A tap on a mirrored notification — its body, or one of its buttons.
    /// Only the session, approval and question ids are read from it: the
    /// notification's userInfo is data, not instructions, and the store
    /// re-derives everything about that session from the relayed state before
    /// it draws a single button or sends a single message.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // Complete the OS callback independently of main-window presentation.
        // Extract Sendable values before crossing to the UI actor.
        let actionIdentifier = response.actionIdentifier
        let isDismiss = actionIdentifier == UNNotificationDismissActionIdentifier
        let action = NotificationActionID(rawValue: actionIdentifier)
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo[NotificationUserInfoKey.sessionId] as? String
        let approvalID = userInfo[NotificationUserInfoKey.approvalId] as? String
        let questionID = userInfo[NotificationUserInfoKey.questionId] as? String
        let userText = (response as? UNTextInputNotificationResponse)?.userText
        let isTextResponse = response is UNTextInputNotificationResponse
        Task { @MainActor in
            // Save the target before releasing the OS background execution
            // opportunity. This does not wait for a window or navigation.
            defer { completionHandler() }
            let route = WatchNotificationResponseRoute.resolve(action: action, isDismiss: isDismiss,
                                                               sessionID: sessionID, approvalID: approvalID,
                                                               questionID: questionID, userText: userText)
            WatchNavigationDiagnostics.shared.record(Self.diagnostic(for: route, action: action,
                                                                    isTextResponse: isTextResponse))
            guard let sessionID = route.sessionID else { return }
            if let state = WatchComplicationStore.loadState()?.state,
               let source = state.sourceID, let epoch = state.pairingEpoch {
                let intent = WatchNotificationIntent(link: WatchTaskLink(sourceID: source,
                    pairingEpoch: epoch, sessionID: sessionID, completionID: state.task(sessionID)?.completionID))
                if let data = try? JSONEncoder().encode(intent) {
                    UserDefaults.standard.set(data, forKey: "watch.pendingNotificationIntent")
                    WatchNavigationDiagnostics.shared.record("notification.target-saved")
                }
            }
            WatchNotificationRouter.shared.route(route)
            WatchNavigationDiagnostics.shared.record("notification.target-enqueued")
        }
    }

    /// Content-free lifecycle evidence: which kind of tap arrived, never what
    /// it was about.
    private static func diagnostic(for route: WatchNotificationResponseRoute,
                                   action: NotificationActionID?,
                                   isTextResponse: Bool) -> String {
        switch route {
        case .open where action == nil: return "notification.default"
        // Reply arriving with no words: on watchOS 27 a mirrored text-input
        // action opens the app without collecting any (WR-09), so the card is
        // where the answer is made. Whether the system handed over a text
        // response at all, or an empty one, is still open; the two are told
        // apart here without recording what was said.
        case .open where action == .answer:
            return isTextResponse ? "notification.action-reply-card.empty-text"
                                  : "notification.action-reply-card.no-text-response"
        case .open: return "notification.action-opens"
        case .decide: return "notification.action-decide"
        // Unbound: an older sender named no question, so the reply is bound
        // at first sight of a relayed state instead of at the hold.
        case .answer(_, nil, _): return "notification.action-answer-unbound"
        case .answer: return "notification.action-answer"
        case .ignore: return action == nil ? "notification.missing-target" : "notification.action-ignored"
        }
    }

    /// A mirrored notification arriving while this app is on screen. The
    /// screen already shows the session, and the store taps out the boundary
    /// itself (`WatchStateStore.feel`), so a banner on top would say the same
    /// thing twice. Same outcome as having no delegate at all, made explicit.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
