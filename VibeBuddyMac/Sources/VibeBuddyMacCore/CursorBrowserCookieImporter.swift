import Foundation
import SQLite3
import SweetCookieKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where Cursor session cookies come from on the Mac (#105).
public enum CursorCookieSourceMode: String, CaseIterable, Sendable, Identifiable {
    case cursorApp
    case manual
    case browserAuto

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cursorApp: return "Cursor app login"
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
        case .cursorApp:
            return try CursorLocalSession.cookieHeader()
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


/// Uses only the selected Cursor app session; never refreshes or persists its token.
/// Source format: CodexBar CursorAppAuth (MIT), independently implemented here.
public enum CursorLocalSession {
    public static func cookieHeader(
        path: String = NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
        now: Date = Date()
    ) throws -> String {
        guard FileManager.default.fileExists(atPath: path) else { throw AccountUsageError.notLoggedIn }
        let token: String
        do { token = try readToken(path: path, immutable: false) }
        catch let error as DatabaseError {
            guard error.code == SQLITE_CANTOPEN,
                  !FileManager.default.fileExists(atPath: path + "-wal"),
                  !FileManager.default.fileExists(atPath: path + "-shm") else {
                throw AccountUsageError.providerUnavailable
            }
            token = try readToken(path: path, immutable: true)
        }
        return try cookieHeader(token: token, now: now)
    }

    static func cookieHeader(token: String, now: Date) throws -> String {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let allowedToken = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 3, token.unicodeScalars.allSatisfy(allowedToken.contains) else {
            throw AccountUsageError.notLoggedIn
        }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiration = claims["exp"] as? Double, expiration.isFinite,
              expiration > now.timeIntervalSince1970 + 60,
              let subject = claims["sub"] as? String,
              let user = subject.split(separator: "|").last,
              !user.isEmpty,
              user.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) })
        else { throw AccountUsageError.notLoggedIn }
        return "WorkosCursorSessionToken=\(user)%3A%3A\(token)"
    }

    private struct DatabaseError: Error { let code: Int32 }
    private static func readToken(path: String, immutable: Bool) throws -> String {
        var db: OpaquePointer?
        let name = immutable ? URL(fileURLWithPath: path).absoluteString + "?immutable=1" : path
        let result = sqlite3_open_v2(name, &db, SQLITE_OPEN_READONLY | (immutable ? SQLITE_OPEN_URI : 0), nil)
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { throw DatabaseError(code: result) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepared == SQLITE_OK else { throw DatabaseError(code: prepared) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            if step == SQLITE_DONE { throw AccountUsageError.notLoggedIn }
            throw DatabaseError(code: step)
        }
        guard let bytes = sqlite3_column_blob(statement, 0) else { throw AccountUsageError.notLoggedIn }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let utf16 = !data.isEmpty && data.count.isMultiple(of: 2) && stride(from: 1, to: data.count, by: 2).allSatisfy { data[$0] == 0 }
        guard let token = String(data: data, encoding: utf16 ? .utf16LittleEndian : .utf8), !token.isEmpty else {
            throw AccountUsageError.notLoggedIn
        }
        return token
    }
}
