import SwiftUI
import UserNotifications
import VibeBuddyKit
import WatchKit

/// The Watch's own long look.
///
/// Everything the wrist is told still arrives as the iPhone's notification,
/// mirrored. Its short look — the buzz and the glance you get without raising
/// your arm — belongs to the system and cannot be changed by anyone. The long
/// look, the screen you get when you *do* raise your arm, is ours, and this is
/// the only place a mirrored cue can be given the wrist's own rhythm.
///
/// The action row below this view is deliberately not ours either. It comes
/// from the category the iPhone registered (`Notifier.registerCategories`,
/// where Approve is already the first action) and a tap on it is answered by
/// the iPhone, which holds the pairing. Apple routes background actions to the
/// original notification target, so these mirrored notifications register their
/// categories on iPhone. Registration location does not reroute their replies.
final class WatchNotificationController: WKUserNotificationHostingController<WatchNotificationView> {
    private var content = WatchNotificationContent()

    override var body: WatchNotificationView { WatchNotificationView(content: content) }

    // Home Assistant observed that the default nil suppresses the input prompt;
    // return an empty array explicitly. This behavior is undocumented by Apple.
    // Reference: home-assistant/iOS@425b2a3,
    // Sources/WatchApp/Notifications/DynamicNotificationHostingController.swift.
    override func suggestionsForResponseToAction(
        withIdentifier identifier: String,
        for notification: UNNotification,
        inputLanguage: String
    ) -> [String] {
        []
    }

    /// Called once per notification the system is about to show here — including
    /// each further one in a grouped stack, which reuses this controller and its
    /// SwiftUI view identity. The rhythm therefore plays from here rather than
    /// from `onAppear`, which would only ever fire for the first of a stack.
    override func didReceive(_ notification: UNNotification) {
        content = WatchNotificationContent(notification)
        content.play()
    }
}

/// What the long look can honestly show and say, taken from the notification
/// itself. Nothing is fetched: this screen may open with the app suspended.
struct WatchNotificationContent: Equatable {
    var title: String = ""
    var body: String = ""
    /// The cue this notification announced, when it named one. Completions and
    /// failures carry no category identifier — the iPhone only registers the two
    /// that have buttons — so they land here as `nil` and pass silently.
    var category: NotificationCategory?

    init() {}

    init(_ notification: UNNotification) {
        let content = notification.request.content
        title = content.title
        body = content.body
        category = NotificationCategoryID(rawValue: content.categoryIdentifier).map {
            switch $0 {
            case .approval: return .needsApproval
            case .question: return .needsAnswer
            }
        }
    }

    /// The rhythm for this cue, muted by the same switches the in-app taps obey.
    /// The switches come from the last relayed state on disk, because a long
    /// look can open with no live store behind it.
    @MainActor
    func play() {
        guard let category else {
            WatchHapticPlayer.shared.play([], reason: "long look, no category")
            return
        }
        let now = Date()
        let state = WatchComplicationStore.loadState()?.state
        let beats = WatchHaptics.rhythm(for: category,
                                        categories: state?.effectiveCategories ?? .default,
                                        quiet: state?.isQuiet(at: now) ?? false)
        WatchHapticPlayer.shared.play(beats, reason: "long look \(category.rawValue)")
    }
}

struct WatchNotificationView: View {
    let content: WatchNotificationContent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !content.title.isEmpty {
                Text(content.title)
                    .font(CompanionType.font(15, .black))
                    .foregroundStyle(accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            if !content.body.isEmpty {
                Text(content.body)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accent: Color {
        CompanionPalette.status(content.category == nil ? .completeUnread : .requiresInput)
    }
}
