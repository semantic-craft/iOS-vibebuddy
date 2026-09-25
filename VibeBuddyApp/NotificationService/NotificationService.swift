import CloudKit
import UserNotifications
import VibeBuddyKit

/// Fills in a CloudKit cue (ADR-0013 direction D). The push Apple sends from
/// the phone's subscription carries only generic text and three plain fields;
/// this extension:
///
/// - rebuilds the `userInfo` the app's banner buttons, the Watch and
///   `PushCoverage` read (`sessionId` / `approvalId` / `questionId`);
/// - fetches the record for the real title and body (kept in
///   `encryptedValues`, so Apple never sees them), localized with the app's
///   own string table;
/// - applies this phone's sound switches and Quiet mode, since one record
///   reaches every phone on the account.
///
/// APNs pushes from a Mac with its own key carry no `ck` payload and pass
/// through untouched.
// `@unchecked Sendable`: the system calls `didReceive` once per instance; the
// fetch task and the expiry callback only meet in `deliver`, behind the lock.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    /// `deliver` runs from the fetch task or from the system's expiry callback,
    /// whichever comes first; the lock makes it exactly once.
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var identifier: String?
    private var receivedAt = Date()
    private var fetched = false
    private var sentAt: Date?
    private static let appGroup = "group.com.vibebuddy.app"
    private static var group: UserDefaults? { UserDefaults(suiteName: appGroup) }

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo)
                as? CKQueryNotification,
              let kind = CloudKitCue.Kind(subscriptionID: notification.subscriptionID),
              let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.contentHandler = contentHandler
        self.content = content
        let fields = notification.recordFields ?? [:]
        var userInfo = content.userInfo
        for (key, value) in CloudKitCue.userInfo(kind: kind, fields: fields) { userInfo[key] = value }
        content.userInfo = userInfo
        if let session = fields[CloudKitCue.Field.sessionID] as? String { content.threadIdentifier = session }
        let identifier = fields[CloudKitCue.Field.notificationID] as? String
        receivedAt = Date()
        self.identifier = identifier
        let prefs = CloudKitCue.PhonePrefs.load(from: Self.group)
        // Until the record is in hand, present by the phone's own switches with
        // the Mac's loudest intent assumed for a waiting cue.
        apply(CloudKitCue.presentation(for: identifier.flatMap(NotificationIdentity.sound(of:)),
                                       macWantsSound: true, macTimeSensitive: kind.category != nil,
                                       prefs: prefs), soundFile: "default", to: content)

        guard let recordID = notification.recordID else { deliver(); return }
        Task { await self.fetchAndDeliver(recordID, identifier: identifier, prefs: prefs) }
    }

    private func fetchAndDeliver(_ recordID: CKRecord.ID, identifier: String?, prefs: CloudKitCue.PhonePrefs) async {
        if let record = try? await CKContainer(identifier: CloudKitCue.containerID)
            .privateCloudDatabase.record(for: recordID), let content {
            fill(content, from: record, identifier: identifier, prefs: prefs)
            fetched = true
            sentAt = record[CloudKitCue.Field.sentAt] as? Date
        }
        deliver()
    }

    private func fill(_ content: UNMutableNotificationContent, from record: CKRecord, identifier: String?,
                      prefs: CloudKitCue.PhonePrefs) {
        let values = record.encryptedValues
        let appBundle = Self.appBundle
        if let key = values[CloudKitCue.EncryptedField.titleKey] as? String {
            let format = appBundle.localizedString(forKey: key, value: key, table: nil)
            let args = values[CloudKitCue.EncryptedField.titleArgs] as? [String] ?? []
            content.title = args.reduce(format) { text, arg in
                guard let range = text.range(of: "%@") else { return text }
                return text.replacingCharacters(in: range, with: arg)
            }
        } else if let title = values[CloudKitCue.EncryptedField.title] as? String {
            content.title = title
        }
        if let key = values[CloudKitCue.EncryptedField.bodyKey] as? String {
            content.body = appBundle.localizedString(forKey: key, value: key, table: nil)
        } else if let body = values[CloudKitCue.EncryptedField.body] as? String {
            content.body = body
        }
        if let subtitle = values[CloudKitCue.EncryptedField.subtitle] as? String { content.subtitle = subtitle }
        let soundFile = values[CloudKitCue.EncryptedField.sound] as? String ?? ""
        let timeSensitive = values[CloudKitCue.EncryptedField.timeSensitive] as? Bool ?? false
        apply(CloudKitCue.presentation(for: identifier.flatMap(NotificationIdentity.sound(of:)),
                                       macWantsSound: !soundFile.isEmpty, macTimeSensitive: timeSensitive,
                                       prefs: prefs), soundFile: soundFile, to: content)
    }

    private func apply(_ presentation: CloudKitCue.Presentation, soundFile: String,
                       to content: UNMutableNotificationContent) {
        if presentation.playsSound {
            content.sound = soundFile == "default" || soundFile.isEmpty
                ? .default : UNNotificationSound(named: UNNotificationSoundName(soundFile))
        } else {
            content.sound = nil
        }
        content.interruptionLevel = presentation.passive ? .passive
            : presentation.timeSensitive ? .timeSensitive : .active
    }

    /// The containing app, whose `Localizable.strings` has the push keys.
    private static var appBundle: Bundle {
        let url = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: url) ?? .main
    }

    private func deliver() {
        lock.lock()
        let handler = contentHandler
        contentHandler = nil
        lock.unlock()
        guard let handler, let content else { return }
        if let identifier {
            CloudKitCue.Receipt.append(.init(notificationID: identifier, receivedAt: receivedAt, sentAt: sentAt,
                                             fetched: fetched, passive: content.interruptionLevel == .passive),
                                       to: CloudKitCue.Receipt.url(appGroup: Self.appGroup))
        }
        handler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        deliver()
    }
}
