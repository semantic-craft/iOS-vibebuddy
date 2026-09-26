import Foundation

/// The closed-app cue a Mac without an APNs key sends through the user's own
/// iCloud private database (ADR-0013 direction D, public-push ticket 02).
///
/// The Mac saves one `Cue` record per cue; the iPhone's query subscription for
/// that record's kind makes Apple's CloudKit servers send the alert, and the
/// iPhone's Notification Service Extension fills it in. Everything both sides
/// must agree on lives here, so the record the Mac writes and the subscription
/// and extension that read it cannot drift apart.
public enum CloudKitCue {
    public static let containerID = "iCloud.com.vibebuddy.app"
    public static let zoneName = "Cues"
    public static let recordType = "Cue"

    /// A saved cue has done its job once the push is out, but every device on
    /// the account receives it and a slow one's extension still has to fetch
    /// it — so records expire by age, never on the first receipt.
    public static let lifetime: TimeInterval = 600

    /// Plain fields. The subscription predicate reads `kind`; `desiredKeys`
    /// carries `nid` / `sid` / `rid` in the push itself (CloudKit allows three).
    public enum Field {
        public static let kind = "kind"
        /// `NotificationIdentity.id`, also the push's collapse id, so the
        /// phone's request identifier, receipts and `PushCoverage` all match.
        public static let notificationID = "nid"
        public static let sessionID = "sid"
        /// The pending approval's or question's id, by kind.
        public static let requestID = "rid"
        public static let sentAt = "sentAt"
    }

    /// Fields under `encryptedValues`: Apple does not see them, the extension
    /// fetches them.
    public enum EncryptedField {
        public static let title = "title"
        public static let body = "body"
        public static let subtitle = "subtitle"
        /// The phone's string-table keys, as `PushCopy` names them for the
        /// APNs `title-loc-key` / `loc-key`, so the banner reads in the
        /// phone's language on this channel too.
        public static let titleKey = "titleKey"
        public static let titleArgs = "titleArgs"
        public static let bodyKey = "bodyKey"
        /// The bundled sound this cue would play, empty for silent.
        public static let sound = "sound"
        public static let timeSensitive = "ts"
    }

    public static let desiredKeys = [Field.notificationID, Field.sessionID, Field.requestID]

    /// One subscription per kind: the category is fixed on a subscription.
    public enum Kind: String, Sendable, CaseIterable {
        case approval
        case question
        case other

        public init(category: NotificationCategoryID?) {
            switch category {
            case .approval: self = .approval
            case .question: self = .question
            case nil: self = .other
            }
        }

        public var category: NotificationCategoryID? {
            switch self {
            case .approval: .approval
            case .question: .question
            case .other: nil
            }
        }

        public var subscriptionID: String { "cue-\(rawValue)" }

        public init?(subscriptionID: String?) {
            guard let subscriptionID, subscriptionID.hasPrefix("cue-"),
                  let kind = Kind(rawValue: String(subscriptionID.dropFirst(4))) else { return nil }
            self = kind
        }

        /// What Apple shows if the extension cannot fetch the record in time.
        /// Generic on purpose: this text is visible to Apple.
        public var fallbackBody: String {
            switch self {
            case .approval: "An agent is waiting for your approval"
            case .question: "An agent has a question for you"
            case .other: "An agent needs your attention"
            }
        }
    }

    /// The `userInfo` the shipping handlers read (`NotificationUserInfoKey`),
    /// rebuilt from the fields a CloudKit push carries. Without it a banner
    /// button, the Watch route and the phone's receipts cannot find the wait.
    public static func userInfo(kind: Kind, fields: [String: Any]) -> [String: String] {
        let requestID = fields[Field.requestID] as? String
        return NotificationUserInfoKey.make(
            sessionId: fields[Field.sessionID] as? String,
            approvalId: kind == .approval ? requestID : nil,
            questionId: kind == .question ? requestID : nil)
    }
}

extension CloudKitCue {
    /// The phone's own sound settings, mirrored into the app group so the
    /// Notification Service Extension can apply them: one CloudKit record
    /// reaches every phone on the account, so each phone quiets it for itself.
    public struct PhonePrefs: Codable, Sendable, Equatable {
        public var playSound: Bool
        public var manualQuiet: Bool
        public var quietHours: QuietHours
        public var categories: NotificationCategoryPrefs

        public init(playSound: Bool = true, manualQuiet: Bool = false,
                    quietHours: QuietHours = QuietHours(), categories: NotificationCategoryPrefs = .default) {
            self.playSound = playSound
            self.manualQuiet = manualQuiet
            self.quietHours = quietHours
            self.categories = categories
        }

        static let key = "cloudKitCuePhonePrefs"

        public static func load(from defaults: UserDefaults?) -> PhonePrefs {
            guard let data = defaults?.data(forKey: key),
                  let prefs = try? JSONDecoder().decode(PhonePrefs.self, from: data) else { return PhonePrefs() }
            return prefs
        }

        public func save(to defaults: UserDefaults?) {
            guard let data = try? JSONEncoder().encode(self) else { return }
            defaults?.set(data, forKey: Self.key)
        }
    }

    /// How this phone presents a cue the Mac sent at `sentLevel`'s loudness.
    /// The extension cannot drop a notification, so a category this phone
    /// switched off, or Quiet mode below a banner, lands `passive` and silent
    /// — in Notification Center, never a banner or a sound.
    public struct Presentation: Equatable, Sendable {
        public var playsSound: Bool
        public var timeSensitive: Bool
        public var passive: Bool
    }

    public static func presentation(for sound: NotificationSound?, macWantsSound: Bool, macTimeSensitive: Bool,
                                    prefs: PhonePrefs, now: Date = Date()) -> Presentation {
        let quiet = Presentation(playsSound: false, timeSensitive: false, passive: true)
        guard let sound else {
            return Presentation(playsSound: macWantsSound && prefs.playSound, timeSensitive: false, passive: false)
        }
        guard prefs.categories.isEnabled(sound) else { return quiet }
        var level: DeliveryLevel = macWantsSound ? .bannerSound : .banner
        if prefs.manualQuiet || prefs.quietHours.isQuiet(at: now) {
            level = min(level, DeliveryMatrix.level(for: sound, attention: .muted))
        }
        guard level.interrupts else { return quiet }
        return Presentation(playsSound: level.makesSound && prefs.playSound,
                            timeSensitive: macTimeSensitive && level == .bannerSound,
                            passive: false)
    }
}

extension CloudKitCue {
    /// One CloudKit cue the phone's extension handled: proof the push arrived,
    /// when, and whether the record could be read. The phone keeps the last few
    /// in the app group and reports them with its registration, so the Mac can
    /// tell "Apple never delivered it" from "delivered, details unreadable".
    public struct Receipt: Codable, Sendable, Equatable {
        public var notificationID: String
        public var receivedAt: Date
        /// When the Mac started saving the record (its `sentAt`), once fetched.
        public var sentAt: Date?
        public var fetched: Bool
        public var passive: Bool

        public init(notificationID: String, receivedAt: Date, sentAt: Date? = nil, fetched: Bool, passive: Bool) {
            self.notificationID = notificationID
            self.receivedAt = receivedAt
            self.sentAt = sentAt
            self.fetched = fetched
            self.passive = passive
        }

        public static let kept = 20

        /// A file, not app-group `UserDefaults`: the extension and the app are
        /// separate processes, and a running app can keep reading a stale
        /// cached suite.
        public static func url(appGroup: String) -> URL? {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
                .appendingPathComponent("cloudkit-cue-receipts.json")
        }

        public static func load(from url: URL?) -> [Receipt] {
            guard let url, let data = try? Data(contentsOf: url),
                  let receipts = try? JSONDecoder().decode([Receipt].self, from: data) else { return [] }
            return receipts
        }

        public static func append(_ receipt: Receipt, to url: URL?) {
            guard let url else { return }
            let receipts = (load(from: url) + [receipt]).suffix(kept)
            guard let data = try? JSONEncoder().encode(Array(receipts)) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
