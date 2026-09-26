import CloudKit
import Foundation
import VibeBuddyKit

/// The iPhone half of the CloudKit cue channel (ADR-0013 direction D): the
/// subscriptions that turn a Mac's `Cue` record into an alert, and the iCloud
/// user this phone reports so the Mac knows it can reach it.
///
/// A Mac with its own APNs key never writes records, so these subscriptions
/// stay idle there; nothing here needs to know which channel the Mac uses.
actor CloudKitCues {
    static let shared = CloudKitCues()

    /// `CKContainer` traps in a build without the iCloud entitlement, and the
    /// QA scripts build the simulator app with `CODE_SIGNING_ALLOWED=NO`. A
    /// simulator run opts in with `VIBEBUDDY_CLOUDKIT=1`; a device build is
    /// always signed with the entitlement.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["VIBEBUDDY_CLOUDKIT"] == "1"
        #else
        true
        #endif
    }

    private lazy var container = CKContainer(identifier: CloudKitCue.containerID)
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitCue.zoneName, ownerName: CKCurrentUserDefaultName)
    private var readyUser: String?

    /// The account, the zone and the three subscriptions; again on every
    /// foreground until it has all worked once. Returns this phone's iCloud
    /// user only when the subscriptions are in place — a Mac told "reachable"
    /// before that would write records no push ever comes from — "" when
    /// iCloud is definitely not usable, so the Mac forgets what it knew, and
    /// nil after a transient error, so it does not.
    func setUp() async -> String? {
        guard Self.isAvailable else { return nil }
        if let readyUser { return readyUser }
        do {
            guard try await container.accountStatus() == .available else { return "" }
            let user = try await container.userRecordID().recordName
            _ = try await container.privateCloudDatabase.modifyRecordZones(
                saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            do {
                try await saveSubscriptions()
            } catch {
                // A fresh Development container has no `Cue` type until the
                // first record; Production has it from the deployed schema.
                try await seedSchema()
                try await saveSubscriptions()
            }
            readyUser = user
            return user
        } catch let error as CKError where Self.isTransient(error) {
            // Offline, throttled, iCloud busy: say nothing, so the Mac keeps
            // the user it knew; the next foreground tries again.
            return nil
        } catch is CKError {
            // A definite failure — no subscriptions can exist (e.g. the
            // Production schema lacks the `Cue` type): the Mac must not count
            // on this phone.
            return ""
        } catch {
            return nil
        }
    }

    private static func isTransient(_ error: CKError) -> Bool {
        [.networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
         .zoneBusy, .notAuthenticated, .accountTemporarilyUnavailable].contains(error.code)
    }

    private func saveSubscriptions() async throws {
        let subscriptions = CloudKitCue.Kind.allCases.map { kind -> CKQuerySubscription in
            let subscription = CKQuerySubscription(
                recordType: CloudKitCue.recordType,
                predicate: NSPredicate(format: "%K == %@", CloudKitCue.Field.kind, kind.rawValue),
                subscriptionID: kind.subscriptionID, options: [.firesOnRecordCreation])
            subscription.zoneID = zoneID
            let info = CKSubscription.NotificationInfo()
            // Apple sees this text; the extension replaces it with the
            // encrypted copy it fetches.
            info.title = "VibeBuddy"
            info.alertBody = kind.fallbackBody
            info.soundName = "default"
            info.category = kind.category?.rawValue
            info.collapseIDKey = CloudKitCue.Field.notificationID
            info.desiredKeys = CloudKitCue.desiredKeys
            info.shouldSendMutableContent = true
            // Same as the APNs path: a waiting cue also wakes the app to
            // deliver held decisions or warn that the Mac is unreachable
            // (ADR-0032).
            info.shouldSendContentAvailable = kind.category != nil
            subscription.notificationInfo = info
            return subscription
        }
        let result = try await container.privateCloudDatabase.modifySubscriptions(saving: subscriptions, deleting: [])
        for (_, outcome) in result.saveResults { _ = try outcome.get() }
    }

    private func seedSchema() async throws {
        let id = CKRecord.ID(recordName: "schema-seed", zoneID: zoneID)
        let record = CKRecord(recordType: CloudKitCue.recordType, recordID: id)
        record[CloudKitCue.Field.kind] = "seed"
        record[CloudKitCue.Field.notificationID] = "seed"
        record[CloudKitCue.Field.sessionID] = "seed"
        record[CloudKitCue.Field.requestID] = "seed"
        record[CloudKitCue.Field.sentAt] = Date()
        for key in [CloudKitCue.EncryptedField.title, CloudKitCue.EncryptedField.body,
                    CloudKitCue.EncryptedField.subtitle, CloudKitCue.EncryptedField.sound,
                    CloudKitCue.EncryptedField.titleKey, CloudKitCue.EncryptedField.bodyKey] {
            record.encryptedValues[key] = "seed"
        }
        record.encryptedValues[CloudKitCue.EncryptedField.titleArgs] = ["seed"]
        record.encryptedValues[CloudKitCue.EncryptedField.timeSensitive] = false
        _ = try await container.privateCloudDatabase.modifyRecords(saving: [record], deleting: [])
        _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: [id])
    }
}
