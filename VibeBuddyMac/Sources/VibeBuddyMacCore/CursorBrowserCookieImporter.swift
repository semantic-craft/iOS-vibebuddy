import Foundation
import SweetCookieKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where Cursor session cookies come from on the Mac (#105).
public enum CursorCookieSourceMode: String, CaseIterable, Sendable, Identifiable {
    case manual
    case browserAuto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .manual: return "Paste Cookie"
        case .browserAuto: return "Import from browser"
        }
    }
}

public enum CursorCookieSourceSettings {
    public static let modeKey = "cursorCookieSourceMode"

    public static func mode(
        defaults: UserDefaults = .standard
    ) -> CursorCookieSourceMode {
        guard let raw = defaults.string(forKey: modeKey),
              let mode = CursorCookieSourceMode(rawValue: raw) else {
            return .manual
        }
        return mode
    }

    public static func setMode(
        _ mode: CursorCookieSourceMode,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}

/// Import seam so unit tests never touch real browser stores.
public protocol CursorBrowserCookieImporting: Sendable {
    /// Returns a Cookie request header when a usable Cursor session is found.
    func importSessionCookieHeader(allowKeychainPrompt: Bool) throws -> String
}

/// CodexBar-style Cursor session cookie names / domains (MIT-documented shapes;
/// reimplemented against SweetCookieKit, not vendoring CodexBar).
public struct CursorBrowserCookieImporter: CursorBrowserCookieImporting {
    public static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "wos-session",
        "__Secure-wos-session",
        "authjs.session-token",
        "__Secure-authjs.session-token",
    ]

    public static let cookieDomains = [
        "cursor.com",
        "www.cursor.com",
        "cursor.sh",
        "authenticator.cursor.sh",
    ]

    private let client: BrowserCookieClient
    private let browsers: [Browser]

    public init(
        client: BrowserCookieClient = BrowserCookieClient(),
        browsers: [Browser] = Browser.defaultImportOrder
    ) {
        self.client = client
        self.browsers = browsers
    }

    public func importSessionCookieHeader(allowKeychainPrompt: Bool) throws -> String {
        // SweetCookieKit `.suffix` over-fetches (`evilcursor.com`); we re-filter
        // with dot-boundary matching before accepting any cookie (#114 M3).
        let query = BrowserCookieQuery(domains: Self.cookieDomains, domainMatch: .suffix)
        let load: () throws -> [BrowserCookieStoreRecords] = {
            try self.client.records(matching: query, in: self.browsers)
        }
        let groups: [BrowserCookieStoreRecords]
        if allowKeychainPrompt {
            groups = try load()
        } else {
            groups = try BrowserCookieKeychainAccessGate.withUserInteractionDisallowed(load)
        }

        // Prefer known session cookie names only. Do not accept the weak
        // "any cookie on a Cursor-ish domain" fallback — that path can persist
        // junk into Keychain (#114 M3).
        if let header = Self.cookieHeader(from: groups, requireKnownSessionName: true) {
            return header
        }
        throw AccountUsageError.notLoggedIn
    }

    /// Dot-boundary domain match: `host == domain || host.hasSuffix("." + domain)`.
    /// Rejects suffix collisions such as `evilcursor.com` vs `cursor.com`.
    public static func matchesAllowedDomain(
        _ host: String,
        allowedDomains: [String] = cookieDomains
    ) -> Bool {
        let haystack = normalizeDomain(host)
        guard !haystack.isEmpty else { return false }
        return allowedDomains.contains { pattern in
            let needle = normalizeDomain(pattern)
            guard !needle.isEmpty else { return false }
            return haystack == needle || haystack.hasSuffix("." + needle)
        }
    }

    static func normalizeDomain(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix(".") {
            value.removeFirst()
        }
        return value
    }

    static func cookieHeader(
        from groups: [BrowserCookieStoreRecords],
        requireKnownSessionName: Bool
    ) -> String? {
        for group in groups {
            let allowed = group.records.filter { matchesAllowedDomain($0.domain) }
            guard !allowed.isEmpty else { continue }
            let cookies = BrowserCookieClient.makeHTTPCookies(allowed, origin: .domainBased)
            guard !cookies.isEmpty else { continue }
            let hasNamed = cookies.contains { sessionCookieNames.contains($0.name) }
            if requireKnownSessionName, !hasNamed { continue }
            return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        }
        return nil
    }
}

/// Resolves the Cookie header using the user's chosen source mode.
public enum CursorCookieResolver {
    public static func resolve(
        mode: CursorCookieSourceMode = CursorCookieSourceSettings.mode(),
        manualCookie: String? = nil,
        loadManual: () -> String? = { CursorSessionCookieStore.loadManual() },
        importer: CursorBrowserCookieImporting = CursorBrowserCookieImporter(),
        allowKeychainPrompt: Bool = false,
        persistImportedCookie: (String) -> Void = {
            _ = CursorSessionCookieStore.saveImportedIfChanged($0)
        }
    ) throws -> String {
        let manual = (manualCookie ?? loadManual())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .manual:
            guard let manual, !manual.isEmpty else { throw AccountUsageError.notLoggedIn }
            return manual
        case .browserAuto:
            do {
                let imported = try importer.importSessionCookieHeader(
                    allowKeychainPrompt: allowKeychainPrompt
                )
                persistImportedCookie(imported)
                return imported
            } catch {
                // Independent manual slot — never the imported account (#114 M1).
                if let manual, !manual.isEmpty { return manual }
                throw (error as? AccountUsageError) ?? AccountUsageError.notLoggedIn
            }
        }
    }
}
