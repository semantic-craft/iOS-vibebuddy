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

    private let container = CKContainer(identifier: CloudKitCue.containerID)
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitCue.zoneName, ownerName: CKCurrentUserDefaultName)
    private(set) var userRecordName: String?
    private var ready = false

    /// Once per launch: the account, the zone and the three subscriptions.
    /// Returns the user record name when iCloud is usable, for the Mac.
    @discardableResult
    func setUp() async -> String? {
        guard !ready else { return userRecordName }
        do {
            guard try await container.accountStatus() == .available else { return nil }
            userRecordName = try await container.userRecordID().recordName
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
            ready = true
        } catch {
            ready = false
        }
        return userRecordName
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
