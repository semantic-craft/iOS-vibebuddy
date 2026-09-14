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
    public static func sessionURL(id: String, completionNotificationID: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = sessionHost
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        if let completionNotificationID {
            components.queryItems?.append(URLQueryItem(name: "completionNotification", value: completionNotificationID))
        }
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
    public static func completionNotificationID(from url: URL) -> String? {
        guard sessionId(from: url) != nil else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == "completionNotification" })?.value
    }

    /// `vibebuddy://quota/<provider>`: the quota widgets' tap, on the phone
    /// and (with the same path segments) the Watch's complications.
    public static let quotaHost = "quota"

    /// The Usage page for one provider, or its head (`/all`) for `nil`.
    public static func quotaURL(_ provider: AccountUsageProvider?) -> URL {
        URL(string: "\(scheme)://\(quotaHost)/\(provider?.rawValue ?? "all")")!
    }

    /// `nil` when the URL is not a quota link; `.some(nil)` for a quota link
    /// that names no single provider — `all`, the Watch's `both`, or a
    /// segment a later build added — which opens the page at its head.
    public static func quotaProvider(from url: URL) -> AccountUsageProvider?? {
        guard url.scheme == scheme, url.host == quotaHost else { return nil }
        let segment = url.pathComponents.dropFirst().first ?? ""
        return .some(AccountUsageProvider(rawValue: segment))
    }
}
