import Foundation
import OSLog

/// Bounded, content-free lifecycle evidence. The store owns transport.
@MainActor
final class WatchNavigationDiagnostics {
    static let shared = WatchNavigationDiagnostics()
    private static let key = "watch.navigation.events"
    private let logger = Logger(subsystem: "com.vibebuddy.watch", category: "navigation")
    private var events = UserDefaults.standard.stringArray(forKey: key) ?? []
    var onChange: (() -> Void)?

    var payload: Data? {
        try? JSONSerialization.data(withJSONObject: [
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "events": events
        ])
    }

    func record(_ event: String) {
        logger.notice("\(event, privacy: .public)")
        events.append("\(Date().timeIntervalSince1970) \(event)")
        // Enough for a whole wrist round: at 48 the minutes around the
        // WR-10 dead button were already pushed out when the file was read.
        events = Array(events.suffix(200))
        UserDefaults.standard.set(events, forKey: Self.key)
        onChange?()
    }
}
