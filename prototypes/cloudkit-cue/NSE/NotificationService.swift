import CloudKit
import UserNotifications

/// Runs for every CloudKit alert push (`shouldSendMutableContent`), also when
/// the app was force-quit and the phone is locked. Measures arrival, fetches
/// the record's encrypted detail into the body, asks for Time Sensitive, and
/// writes a `Receipt` the Mac reads back.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let startedAt = Date()
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.content = content

        let notification = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification
        let fields = notification?.recordFields
        let cueID = fields?["cueID"] as? String ?? "?"
        let sentAt = fields?["sentAt"] as? Date
        let locked = (try? Data(contentsOf: CueProto.lockProbeURL)) == nil
        content.interruptionLevel = .timeSensitive
        if let session = fields?["sessionKey"] as? String { content.threadIdentifier = session }

        Task {
            var fetchError: String?
            var detailOK = false
            let fetchStart = Date()
            if let recordID = notification?.recordID {
                do {
                    let record = try await CueProto.database.record(for: recordID)
                    if let detail = record.encryptedValues["detail"] as? String {
                        content.body = detail
                        detailOK = true
                    }
                    if let project = record["project"] as? String { content.subtitle = project }
                } catch {
                    fetchError = CueProto.describe(error)
                }
            } else {
                fetchError = "no recordID in payload"
            }
            let fetchMs = Date().timeIntervalSince(fetchStart) * 1000
            let handedAt = Date()
            var line: [String: Any] = [
                "nse": cueID, "startedAt": startedAt.timeIntervalSince1970, "handedAt": handedAt.timeIntervalSince1970,
                "locked": locked, "detailOK": detailOK, "fetchMs": fetchMs,
            ]
            if let sentAt { line["sentAt"] = sentAt.timeIntervalSince1970 }
            if let fetchError { line["fetchError"] = fetchError }
            CueProto.appendLog(line)
            self.deliver()

            let receipt = CKRecord(recordType: CueProto.receiptType, recordID: CKRecord.ID(recordName: "receipt-\(cueID)-\(Int(startedAt.timeIntervalSince1970 * 1000))", zoneID: CueProto.zoneID))
            receipt["cueID"] = cueID
            receipt["startedAt"] = startedAt
            receipt["handedAt"] = handedAt
            receipt["locked"] = locked ? 1 : 0
            receipt["detailOK"] = detailOK ? 1 : 0
            receipt["fetchMs"] = fetchMs
            receipt["fetchError"] = fetchError
            do {
                try await CueProto.save([receipt])
            } catch {
                CueProto.appendLog(["nse": cueID, "receiptError": CueProto.describe(error)])
            }
        }
    }

    private func deliver() {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        handler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        CueProto.appendLog(["nse": "timeWillExpire"])
        deliver()
    }
}
