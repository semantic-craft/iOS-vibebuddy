import Foundation

/// The `vibebuddy://` deep-link scheme used by the Live Activity / Dynamic Island
/// (and notifications) to open a specific session when tapped.
///
/// Form: `vibebuddy://session?id=<percent-encoded-id>`. The query form round-trips
/// any opaque id (including ones with `/` or `#`); the widget extension builds the
/// same string inline (it deliberately doesn't link VibeBuddyKit), and this type is
/// the canonical definition the app parses against and the tests pin.
public enum VibeBuddyDeepLink {
    public static let scheme = "vibebuddy"
    public static let sessionHost = "session"

    /// Build the deep link that opens `id`.
    public static func sessionURL(id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = sessionHost
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        // Always well-formed for a non-empty scheme/host; the fallback only guards
        // a theoretically-impossible nil so callers get a non-optional URL.
        return components.url ?? URL(string: "\(scheme)://\(sessionHost)")!
    }

    /// Extract the session id from a deep link, or `nil` if it isn't one.
    public static func sessionId(from url: URL) -> String? {
        guard url.scheme == scheme, url.host == sessionHost,
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "id" })?.value,
              !id.isEmpty
        else { return nil }
        return id
    }
}
