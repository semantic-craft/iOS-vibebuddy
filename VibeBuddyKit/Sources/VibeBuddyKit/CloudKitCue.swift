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
