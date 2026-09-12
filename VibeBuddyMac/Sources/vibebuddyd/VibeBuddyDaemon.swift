import Foundation
import VibeBuddyMacCore

/// Headless entry point for Phase B (the menu-bar app wraps this in Phase C).
/// Config via env: VIBEBUDDY_PORT (default 9876), VIBEBUDDY_TOKEN (env wins,
/// including empty; otherwise TokenStore.defaultStore()).
@main
struct VibeBuddyDaemon {
    static func main() async throws {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.allSatisfy({ $0 == "--pair" }) else {
            FileHandle.standardError.write(Data("Usage: vibebuddyd [--pair]\n".utf8))
            exit(EXIT_FAILURE)
        }
        let env = ProcessInfo.processInfo.environment
        let port = env["VIBEBUDDY_PORT"].flatMap(Int.init) ?? 9876
        let token: String
        let tokenSource: String
        if let envToken = env["VIBEBUDDY_TOKEN"] {
            token = envToken  // including empty: BearerAuth fail-closed, no store fallback
            tokenSource = "env"
        } else {
            token = try TokenStore.defaultStore().loadOrCreate()
            tokenSource = "TokenStore"
        }
        let journalURL = env["VIBEBUDDY_JOURNAL_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? LifecycleJournalLocation.defaultURL()
        let deliveryURL = env["VIBEBUDDY_DELIVERY_LOG_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? NotificationDeliveryLogLocation.defaultURL()
        // Owner-only, survives a restart: an in-memory registry meant no push
        // reached a closed phone until the phone next cold-launched.
        let registryURL = env["VIBEBUDDY_DEVICE_REGISTRY_PATH"].map {
            URL(fileURLWithPath: $0)
        } ?? DeviceRegistryLocation.defaultURL()
        let deviceTokens = DeviceTokens(url: registryURL)
        if arguments.contains("--pair") {
            await deviceTokens.acceptNewRegistrations()
            FileHandle.standardError.write(Data("Pairing enabled for 120 seconds. Enter this Mac's address and token on the phone.\n".utf8))
        }
        let apnsConfig = APNsConfig.load()
        let deliveryRecorder = NotificationDeliveryRecorder(
            url: deliveryURL, apnsConfigured: apnsConfig != nil)
        // Phones report the cues they posted themselves here; the pusher stands
        // its own push down for those (ADR-0012).
        let phoneReceipts = PhoneReceipts(recorder: deliveryRecorder)
        let pusher = apnsConfig.flatMap {
            try? APNsPusher(config: $0, recorder: deliveryRecorder, receipts: phoneReceipts)
        }
        // The app-server monitor raises cards the phone answers through the
        // same routes as hook-raised ones, so the two share every registry.
        let approvalRegistry = ApprovalRegistry()
        let allowStore = VibeBuddyAllowStore()
        let sessionAllow = SessionAllowList()
        let approvalContext = ApprovalContextStore()
        let questionRegistry = QuestionRegistry()
        let store = SessionStore(
            sourceID: DaemonIdentity.load(),
            diagnosticsHome: FileManager.default.homeDirectoryForCurrentUser,
            journalURL: journalURL,
            attentionURL: AttentionOverrides.defaultURL(),
            missedURL: env["VIBEBUDDY_MISSED_PATH"].map { URL(fileURLWithPath: $0) }
                ?? MissedLedgerLocation.defaultURL()
        )
        // One follow-up queue for Cursor: the hooks' `stop` drains it for IDE
        // chats, the ACP host for the conversations it carries.
        let cursorFollowups = CursorFollowupQueue()
        let cursorACP = CursorACPMonitor(
            store: store, approvals: approvalRegistry, approvalContext: approvalContext,
            questions: questionRegistry, allowStore: allowStore, sessionAllow: sessionAllow,
            followups: cursorFollowups)
        let server = VibeBuddyServer(
            store: store,
            token: token, port: port, pusher: pusher, phoneReceipts: phoneReceipts,
            deliveryRecorder: deliveryRecorder,
            deviceTokens: deviceTokens,
            codexRolloutMonitor: CodexRolloutMonitor(),
            codexAppServerMonitor: CodexAppServerMonitor(
                approvalRegistry: approvalRegistry, allowStore: allowStore,
                sessionAllow: sessionAllow, approvalContext: approvalContext,
                questionRegistry: questionRegistry),
            approvalRegistry: approvalRegistry, allowStore: allowStore,
            sessionAllow: sessionAllow, approvalContext: approvalContext,
            questionRegistry: questionRegistry,
            cursorACP: cursorACP,
            cursorTranscriptMonitor: CursorTranscriptMonitor(),
            cursorFollowups: cursorFollowups)
        FileHandle.standardError.write(Data(
            "vibebuddyd: listening on 0.0.0.0:\(port) (apns: \(pusher != nil ? "on" : "off"), token: \(tokenSource))\n".utf8))
        try await server.runService()
    }
}
