import CloudKit
import Foundation
import Security
import VibeBuddyKit

/// What the Mac knows about its CloudKit cue channel, for Settings and for the
/// decision whether to use it at all.
public struct CloudKitCueStatus: Equatable, Sendable {
    public enum State: String, Sendable, Equatable {
        /// This build carries no iCloud entitlement (headless `vibebuddyd`, an
        /// ad-hoc build, or a signing run that found no matching profile).
        case notEntitled
        case noAccount
        case restricted
        case temporarilyUnavailable
        case couldNotDetermine
        case available
    }

    public var state: State
    /// This Mac's user record name in `CloudKitCue.containerID`; a paired
    /// phone on the same Apple Account reports the same string.
    public var userRecordName: String?
    /// `Development` or `Production`, from the signed entitlement.
    public var environment: String
    public var lastError: String?

    public init(state: State, userRecordName: String? = nil, environment: String = "Development",
                lastError: String? = nil) {
        self.state = state
        self.userRecordName = userRecordName
        self.environment = environment
        self.lastError = lastError
    }

    public static let notEntitled = CloudKitCueStatus(state: .notEntitled)
}

/// One cue as the CloudKit channel writes it. Title, body and subtitle go
/// under `encryptedValues`; Apple sees only the subscription's generic text.
public struct CloudKitCueOutgoing: Sendable, Equatable {
    public var kind: CloudKitCue.Kind
    public var notificationID: String
    public var sessionID: String
    public var requestID: String?
    public var title: String
    public var body: String
    public var subtitle: String?
    public var localization: PushLocalization?
    /// Bundled sound file name; empty for a silent cue.
    public var sound: String
    public var timeSensitive: Bool
    /// `NotificationSound.rawValue`, for the delivery log.
    public var soundCategory: String

    public init(kind: CloudKitCue.Kind, notificationID: String, sessionID: String, requestID: String?,
                title: String, body: String, subtitle: String? = nil,
                localization: PushLocalization? = nil, sound: String,
                timeSensitive: Bool, soundCategory: String) {
        self.kind = kind
        self.notificationID = notificationID
        self.sessionID = sessionID
        self.requestID = requestID
        self.title = title
        self.body = body
        self.subtitle = subtitle
        self.localization = localization
        self.sound = sound
        self.timeSensitive = timeSensitive
        self.soundCategory = soundCategory
    }
}

/// Saves cue records into the signed-in user's private database; the phone's
/// subscription turns each into an alert (ADR-0013 direction D). Used by the
/// menu-bar app only, and only when this Mac has no APNs key.
///
/// Touching `CKContainer` without the iCloud entitlement traps, so nothing
/// here runs unless `isEntitled` says the signed binary carries it.
public actor CloudKitCueSender {
    private let container: CKContainer
    private let zoneID = CKRecordZone.ID(zoneName: CloudKitCue.zoneName, ownerName: CKCurrentUserDefaultName)
    private let recorder: (any NotificationDeliveryRecording)?
    private let receipts: PhoneReceipts?
    private var zoneReady = false
    private var swept = false
    private(set) var status: CloudKitCueStatus
    private var checkedAt: Date?
    /// Records this process saved and has not deleted yet.
    private var saved: [(id: CKRecord.ID, at: Date)] = []

    /// Nil when the running binary has no iCloud entitlement for the cue
    /// container — the only safe answer, since the first CloudKit call would crash.
    public static func makeIfEntitled(recorder: (any NotificationDeliveryRecording)? = nil,
                                      receipts: PhoneReceipts? = nil) -> CloudKitCueSender? {
        guard let environment = entitledEnvironment() else { return nil }
        return CloudKitCueSender(environment: environment, recorder: recorder, receipts: receipts)
    }

    private init(environment: String, recorder: (any NotificationDeliveryRecording)?, receipts: PhoneReceipts?) {
        self.container = CKContainer(identifier: CloudKitCue.containerID)
        self.recorder = recorder
        self.receipts = receipts
        self.status = CloudKitCueStatus(state: .couldNotDetermine, environment: environment)
    }

    /// The container environment when this process is entitled to the cue
    /// container, else nil. Development is CloudKit's default when the
    /// environment entitlement is absent.
    static func entitledEnvironment() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        func value(_ key: String) -> CFTypeRef? { SecTaskCopyValueForEntitlement(task, key as CFString, nil) }
        guard let containers = value("com.apple.developer.icloud-container-identifiers") as? [String],
              containers.contains(CloudKitCue.containerID),
              let services = value("com.apple.developer.icloud-services") as? [String],
              services.contains("CloudKit") else { return nil }
        return value("com.apple.developer.icloud-container-environment") as? String ?? "Development"
    }

    /// Ask iCloud again: account state and this Mac's user record name. The
    /// menu-bar app asks on every 2 s poll, so an answer is reused for five
    /// minutes when iCloud is available and 30 s when it is not.
    @discardableResult
    public func refreshStatus(now: Date = Date()) async -> CloudKitCueStatus {
        if let checkedAt {
            let age = now.timeIntervalSince(checkedAt)
            if age < (status.state == .available ? 300 : 30) { return status }
        }
        checkedAt = now
        do {
            let account = try await container.accountStatus()
            status.state = switch account {
            case .available: .available
            case .noAccount: .noAccount
            case .restricted: .restricted
            case .temporarilyUnavailable: .temporarilyUnavailable
            default: .couldNotDetermine
            }
            if status.state == .available, status.userRecordName == nil {
                status.userRecordName = try await container.userRecordID().recordName
            }
            status.lastError = nil
        } catch {
            status.lastError = Self.describe(error)
        }
        return status
    }

    public func currentStatus() -> CloudKitCueStatus { status }

    /// Save one cue. `tokens` are the push tokens of the phones this cue is
    /// for: a receipt from every one of them (ADR-0012) means each has shown
    /// the cue itself, so nothing is saved. A saved record cannot be taken
    /// back, which is why the hold happens first.
    public func send(_ cue: CloudKitCueOutgoing, tokens: [String], waitSince: Date?, holdForPhone: Bool,
                     validate: @escaping @Sendable () async -> Bool = { true }) async -> NotificationDeliveryClassification {
        if let receipts, !tokens.isEmpty {
            var covered = true
            for token in tokens where await receipts.receipt(for: cue.notificationID, since: waitSince,
                                                                from: token, hold: holdForPhone) == nil {
                covered = false
                break
            }
            if covered {
                return await log(.init(outcome: .skipped, failureReason: CueSkipReason.phonePosted.rawValue), cue)
            }
        }
        guard await validate() else {
            return await log(.init(outcome: .skipped, failureReason: "completionInvalidated"), cue)
        }
        let now = Date()
        do {
            try await ensureZone()
            let id = CKRecord.ID(recordName: "\(cue.notificationID)-\(Int(now.timeIntervalSince1970 * 1000))",
                                 zoneID: zoneID)
            let record = CKRecord(recordType: CloudKitCue.recordType, recordID: id)
            record[CloudKitCue.Field.kind] = cue.kind.rawValue
            record[CloudKitCue.Field.notificationID] = cue.notificationID
            record[CloudKitCue.Field.sessionID] = cue.sessionID
            record[CloudKitCue.Field.requestID] = cue.requestID
            record[CloudKitCue.Field.sentAt] = now
            record.encryptedValues[CloudKitCue.EncryptedField.title] = cue.title
            record.encryptedValues[CloudKitCue.EncryptedField.body] = cue.body
            record.encryptedValues[CloudKitCue.EncryptedField.subtitle] = cue.subtitle
            record.encryptedValues[CloudKitCue.EncryptedField.titleKey] = cue.localization?.titleKey
            record.encryptedValues[CloudKitCue.EncryptedField.titleArgs] = cue.localization?.titleArgs
            record.encryptedValues[CloudKitCue.EncryptedField.bodyKey] = cue.localization?.bodyKey
            record.encryptedValues[CloudKitCue.EncryptedField.sound] = cue.sound
            record.encryptedValues[CloudKitCue.EncryptedField.timeSensitive] = cue.timeSensitive
            let result = try await container.privateCloudDatabase.modifyRecords(
                saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
            _ = try result.saveResults[id]?.get()
            saved.append((id, now))
            status.lastError = nil
            await sweep(now: now)
            return await log(.init(outcome: .accepted, failureReason: nil), cue)
        } catch {
            status.lastError = Self.describe(error)
            return await log(.init(outcome: .failed, failureReason: Self.reason(error)), cue)
        }
    }

    /// Delete cue records older than `CloudKitCue.lifetime`. The first call in
    /// a process also finds the ones a previous run left behind.
    public func sweep(now: Date = Date()) async {
        var expired = saved.filter { now.timeIntervalSince($0.at) > CloudKitCue.lifetime }.map(\.id)
        if !swept, zoneReady {
            swept = true
            expired += await leftovers(now: now)
        }
        guard !expired.isEmpty else { return }
        let result = try? await container.privateCloudDatabase.modifyRecords(
            saving: [], deleting: expired, savePolicy: .allKeys, atomically: false)
        let gone = Set(result?.deleteResults.compactMap { id, outcome -> CKRecord.ID? in
            if case .failure(let error) = outcome, (error as? CKError)?.code != .unknownItem { return nil }
            return id
        } ?? [])
        saved.removeAll { gone.contains($0.id) }
    }

    /// Cue records older than their lifetime, read as zone changes so no query
    /// index is needed.
    private func leftovers(now: Date) async -> [CKRecord.ID] {
        var found: [CKRecord.ID] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            guard let changes = try? await container.privateCloudDatabase.recordZoneChanges(
                inZoneWith: zoneID, since: token) else { break }
            for (id, result) in changes.modificationResultsByID {
                guard case .success(let modification) = result,
                      modification.record.recordType == CloudKitCue.recordType else { continue }
                let sent = modification.record[CloudKitCue.Field.sentAt] as? Date ?? .distantPast
                if now.timeIntervalSince(sent) > CloudKitCue.lifetime { found.append(id) }
            }
            token = changes.changeToken
            more = changes.moreComing
        }
        return found
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        zoneReady = true
    }

    private func log(_ classified: NotificationDeliveryClassification,
                     _ cue: CloudKitCueOutgoing) async -> NotificationDeliveryClassification {
        await recorder?.record(NotificationDeliveryRecord(
            channel: .cloudkit, outcome: classified.outcome, sessionID: cue.sessionID,
            sound: cue.soundCategory, failureReason: classified.failureReason, timestamp: Date()))
        return classified
    }

    static func reason(_ error: Error) -> String {
        if let ck = error as? CKError { return "cloudKit\(ck.code.rawValue)" }
        return "cloudKitError"
    }

    static func describe(_ error: Error) -> String {
        if let ck = error as? CKError { return "CKError \(ck.code.rawValue): \(ck.localizedDescription)" }
        return error.localizedDescription
    }
}
