import CloudKit
import Foundation

/// Names shared by the Mac writer, the iPhone app and its Notification
/// Service Extension. Prototype only (public-push ticket 01); nothing in the
/// shipping apps links this file.
enum CueProto {
    static let containerID = "iCloud.com.vibebuddy.cueproto"
    static let appGroup = "group.com.vibebuddy.cueproto"
    static let zoneID = CKRecordZone.ID(zoneName: "Cues", ownerName: CKCurrentUserDefaultName)

    /// Mac → iPhone. Saving one fires the phone's query subscription.
    static let cueType = "Cue"
    /// iPhone → Mac, written by the extension when a push lands.
    static let receiptType = "Receipt"
    /// iPhone → Mac, written by the app when a banner button runs.
    static let actionType = "Action"
    /// iPhone → Mac: registration (user record name, clock offset) and the
    /// delivered-notification readback.
    static let deviceType = "Device"
    static let deliveredType = "Delivered"

    static let approvalSubscriptionID = "cue-approval"
    static let questionSubscriptionID = "cue-question"

    /// Same identifiers as `NotificationCategoryID` / `NotificationActionID`
    /// in VibeBuddyKit, so A-12 can reuse the shipping categories unchanged.
    static let approvalCategory = "approval"
    static let questionCategory = "question"

    static var container: CKContainer { CKContainer(identifier: containerID) }
    static var database: CKDatabase { container.privateCloudDatabase }

    static var groupURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)!
    }

    /// Written by the app with `.complete` protection; unreadable from ~10 s
    /// after the phone locks, so the extension can tell whether it ran locked.
    static var lockProbeURL: URL { groupURL.appendingPathComponent("lockprobe") }
    static var logURL: URL { groupURL.appendingPathComponent("events.jsonl") }

    static func appendLog(_ fields: [String: Any]) {
        var line = fields
        line["at"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: line),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? text.data(using: .utf8)!.write(to: logURL)
        }
    }

    /// Save (last writer wins) and surface the first per-record error, which
    /// `modifyRecords` otherwise returns inside its result dictionary.
    static func save(_ records: [CKRecord], deleting: [CKRecord.ID] = []) async throws {
        let result = try await database.modifyRecords(saving: records, deleting: deleting, savePolicy: .allKeys, atomically: false)
        for (_, outcome) in result.saveResults { _ = try outcome.get() }
        for (_, outcome) in result.deleteResults {
            if case .failure(let error) = outcome, (error as? CKError)?.code != .unknownItem { throw error }
        }
    }

    static func describe(_ error: Error) -> String {
        if let ck = error as? CKError { return "CKError(\(ck.code.rawValue)) \(ck.localizedDescription)" }
        return String(describing: error)
    }
}
