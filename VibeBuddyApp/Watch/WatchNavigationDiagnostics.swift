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
        events = Array(events.suffix(48))
        UserDefaults.standard.set(events, forKey: Self.key)
        onChange?()
    }
}
