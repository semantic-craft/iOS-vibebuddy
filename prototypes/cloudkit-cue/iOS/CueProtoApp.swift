import CloudKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct CueProtoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            StatusView(model: delegate.model)
        }
    }
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var lines: [String] = []

    func note(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        lines.append("\(stamp) \(line)")
        CueProto.appendLog(["app": line])
    }
}

struct StatusView: View {
    @ObservedObject var model: StatusModel

    var body: some View {
        NavigationStack {
            List(model.lines.reversed(), id: \.self) { Text($0).font(.caption.monospaced()) }
                .navigationTitle("Cue Proto")
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = StatusModel()

    /// Mac prototype listener (`CueProtoMac run`) — stands in for the shipping
    /// bearer route the real Approve / Deny would call.
    private var macURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "CueProtoMacURL") as? String).flatMap(URL.init(string:))
    }
    private var macToken: String { Bundle.main.object(forInfoDictionaryKey: "CueProtoToken") as? String ?? "" }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
        application.registerForRemoteNotifications()
        Task { await setUp() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.writeLockProbe()
            Task { await self.uploadDelivered() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in model.note("APNs token registered (\(deviceToken.count) bytes)") }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in model.note("APNs registration failed: \(error)") }
    }

    /// Same identifiers and options as `Notifier.registerCategories()` in the
    /// shipping app: every action is a foreground action (ADR-0033).
    private func registerCategories() {
        let approve = UNNotificationAction(identifier: "approve", title: "Approve", options: [.authenticationRequired, .foreground])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive, .foreground])
        let reply = UNTextInputNotificationAction(identifier: "answer", title: "Reply", options: [.foreground], textInputButtonTitle: "Send", textInputPlaceholder: "Answer")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: CueProto.approvalCategory, actions: [approve, deny], intentIdentifiers: []),
            UNNotificationCategory(identifier: CueProto.questionCategory, actions: [reply], intentIdentifiers: []),
        ])
    }

    private func note(_ line: String) async {
        await MainActor.run { model.note(line) }
    }

    private func setUp() async {
        writeLockProbe()
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        await note("categories: " + categories.map { "\($0.identifier)[\($0.actions.map(\.identifier).joined(separator: ","))]" }.sorted().joined(separator: " "))
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            await note("notifications granted=\(granted) timeSensitive=\(settings.timeSensitiveSetting.rawValue)")
        } catch {
            await note("notification auth failed: \(error)")
        }

        let container = CueProto.container
        do {
            let status = try await container.accountStatus()
            let user = try await container.userRecordID()
            await note("iCloud status=\(status.rawValue) user=\(user.recordName)")
            _ = try await CueProto.database.modifyRecordZones(saving: [CKRecordZone(zoneID: CueProto.zoneID)], deleting: [])
            try await seedSchema()
            try await saveSubscriptions()
            let offset = await clockOffset()
            let device = CKRecord(recordType: CueProto.deviceType, recordID: CKRecord.ID(recordName: "device-\(UIDevice.current.identifierForVendor?.uuidString ?? "phone")", zoneID: CueProto.zoneID))
            device["userRecordName"] = user.recordName
            device["name"] = UIDevice.current.name
            device["registeredAt"] = Date()
            device["clockOffset"] = offset.map { $0.offset } // mac − phone, seconds
            device["clockRTT"] = offset.map { $0.rtt }
            try await CueProto.save([device])
            await note("registered; clock offset \(offset.map { String(format: "%.3f s (rtt %.3f)", $0.offset, $0.rtt) } ?? "unavailable")")
        } catch {
            await note("CloudKit setup failed: \(CueProto.describe(error))")
        }
        await uploadDelivered()
    }

    private func writeLockProbe() {
        try? Data("probe".utf8).write(to: CueProto.lockProbeURL, options: [.completeFileProtection])
    }

    /// Development schema is created on first save; a subscription on a record
    /// type that does not exist yet is rejected, so write and delete one of each.
    private func seedSchema() async throws {
        let seed = CKRecord(recordType: CueProto.cueType, recordID: CKRecord.ID(recordName: "seed-cue", zoneID: CueProto.zoneID))
        seed["cueID"] = "seed"; seed["kind"] = "seed"; seed["project"] = "seed"; seed["sessionKey"] = "seed"; seed["sentAt"] = Date()
        seed.encryptedValues["detail"] = "seed"
        try await CueProto.save([seed])
        try await CueProto.save([], deleting: [seed.recordID])
    }

    private func saveSubscriptions() async throws {
        func subscription(id: String, kind: String, category: String) -> CKQuerySubscription {
            let sub = CKQuerySubscription(recordType: CueProto.cueType, predicate: NSPredicate(format: "kind == %@", kind), subscriptionID: id, options: [.firesOnRecordCreation])
            sub.zoneID = CueProto.zoneID
            let info = CKSubscription.NotificationInfo()
            // Generic on purpose: Apple sees this text. The extension replaces
            // the body with the encrypted detail it fetches from the record.
            info.title = "VibeBuddy"
            info.alertBody = kind == "question" ? "An agent has a question" : "An agent is waiting for approval"
            info.soundName = "default"
            info.category = category
            info.collapseIDKey = "sessionKey"
            info.shouldSendMutableContent = true
            info.desiredKeys = ["cueID", "sentAt", "sessionKey"]
            sub.notificationInfo = info
            return sub
        }
        let subs = [
            subscription(id: CueProto.approvalSubscriptionID, kind: "approval", category: CueProto.approvalCategory),
            subscription(id: CueProto.questionSubscriptionID, kind: "question", category: CueProto.questionCategory),
        ]
        let result = try await CueProto.database.modifySubscriptions(saving: subs, deleting: [])
        for (id, outcome) in result.saveResults {
            switch outcome {
            case .success: await note("subscription \(id) saved")
            case .failure(let error): await note("subscription \(id) failed: \(CueProto.describe(error))")
            }
        }
    }

    /// NTP-style handshake with the Mac listener: the best of five round trips.
    private func clockOffset() async -> (offset: Double, rtt: Double)? {
        guard let base = macURL else { return nil }
        var best: (offset: Double, rtt: Double)?
        for _ in 0..<5 {
            var request = URLRequest(url: base.appendingPathComponent("time"), timeoutInterval: 3)
            request.setValue("Bearer \(macToken)", forHTTPHeaderField: "Authorization")
            let t1 = Date().timeIntervalSince1970
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mac = json["now"] as? Double else { continue }
            let t3 = Date().timeIntervalSince1970
            let sample = (offset: mac - (t1 + t3) / 2, rtt: t3 - t1)
            if best == nil || sample.rtt < best!.rtt { best = sample }
        }
        return best
    }

    /// What actually reached Notification Center: delivery date, the level the
    /// extension asked for, and whether the extension's body stuck.
    private func uploadDelivered() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let rows: [[String: Any]] = delivered.map { note in
            let fields = (CKNotification(fromRemoteNotificationDictionary: note.request.content.userInfo) as? CKQueryNotification)?.recordFields
            return [
                "id": note.request.identifier,
                "date": note.date.timeIntervalSince1970,
                "cueID": fields?["cueID"] as? String ?? "",
                "category": note.request.content.categoryIdentifier,
                "interruptionLevel": note.request.content.interruptionLevel.rawValue,
                "body": note.request.content.body,
                "thread": note.request.content.threadIdentifier,
            ]
        }
        let log = (try? String(contentsOf: CueProto.logURL, encoding: .utf8)) ?? ""
        let record = CKRecord(recordType: CueProto.deliveredType, recordID: CKRecord.ID(recordName: "delivered-\(UUID().uuidString)", zoneID: CueProto.zoneID))
        record["uploadedAt"] = Date()
        record["rows"] = String(data: (try? JSONSerialization.data(withJSONObject: rows)) ?? Data(), encoding: .utf8)
        record["log"] = String(log.suffix(200_000))
        do {
            try await CueProto.save([record])
            await note("uploaded \(rows.count) delivered notifications")
        } catch {
            await note("delivered upload failed: \(CueProto.describe(error))")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// A banner button: record it and send it back to the Mac the way the
    /// shipping app does — an authenticated HTTP call to the paired Mac.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let receivedAt = Date()
        let state = await MainActor.run { UIApplication.shared.applicationState.rawValue }
        let fields = (CKNotification(fromRemoteNotificationDictionary: response.notification.request.content.userInfo) as? CKQueryNotification)?.recordFields
        let cueID = fields?["cueID"] as? String ?? "?"
        let text = (response as? UNTextInputNotificationResponse)?.userText
        var posted = "no-url"
        if let base = macURL {
            var request = URLRequest(url: base.appendingPathComponent("action"), timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("Bearer \(macToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "cueID": cueID, "action": response.actionIdentifier, "text": text ?? "", "phoneAt": receivedAt.timeIntervalSince1970,
            ])
            do {
                let (_, http) = try await URLSession.shared.data(for: request)
                posted = "http \((http as? HTTPURLResponse)?.statusCode ?? -1)"
            } catch {
                posted = "error \(error.localizedDescription)"
            }
        }
        let record = CKRecord(recordType: CueProto.actionType, recordID: CKRecord.ID(recordName: "action-\(UUID().uuidString)", zoneID: CueProto.zoneID))
        record["cueID"] = cueID
        record["action"] = response.actionIdentifier
        record["text"] = text
        record["receivedAt"] = receivedAt
        record["appState"] = state
        record["macPost"] = posted
        try? await CueProto.save([record])
        await note("action \(response.actionIdentifier) cue=\(cueID) state=\(state) post=\(posted)")
        await uploadDelivered()
    }
}
