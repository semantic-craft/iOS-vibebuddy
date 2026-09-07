import Foundation
import VibeBuddyKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport seam for `GET https://cursor.com/api/usage-summary`.
public protocol CursorUsageTransport: Sendable {
    func cursorData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: CursorUsageTransport {
    public func cursorData(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request)
    }
}

/// Keychain account for the pasted Cursor session Cookie header (#104).
public enum CursorSessionCookieStore {
    public static let keychainAccount = "cursorSessionCookie"

    public static func load(read: (String) -> String? = KeychainStore.get) -> String? {
        read(keychainAccount)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    public static func save(_ value: String?, write: (String?, String) -> Void = KeychainStore.set) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        write(trimmed?.nilIfEmpty, keychainAccount)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Maps Cursor `usage-summary` JSON onto vibebuddy's `AccountUsageSnapshot`.
/// Shapes follow CodexBar's MIT-documented decode (reimplemented, not vendored).
public enum CursorUsageSummaryDecoder {
    public static func decode(_ data: Data, fetchedAt: Date) throws -> AccountUsageSnapshot {
        let summary: CursorUsageSummaryDTO
        do {
            summary = try JSONDecoder().decode(CursorUsageSummaryDTO.self, from: data)
        } catch {
            throw AccountUsageError.incompatibleFormat
        }

        let start = parseTimestamp(summary.billingCycleStart)
        let end = parseTimestamp(summary.billingCycleEnd)
        let duration = durationMinutes(from: start, to: end)

        guard let primaryUsed = primaryUsedPercent(from: summary) else {
            throw AccountUsageError.incompatibleFormat
        }
        guard (0...100).contains(primaryUsed) else {
            throw AccountUsageError.incompatibleFormat
        }

        var secondary: AccountUsageWindow?
        if let onDemand = summary.individualUsage?.onDemand,
           let limit = onDemand.limit, limit > 0 {
            let used = Double(onDemand.used ?? 0)
            let percent = Int(min(100, max(0, used / Double(limit) * 100)).rounded())
            secondary = AccountUsageWindow(
                kind: .secondary,
                usedPercent: percent,
                windowDurationMinutes: duration,
                resetsAt: end
            )
        }

        let plan = summary.membershipType.flatMap { $0.isEmpty ? nil : $0 }
        return AccountUsageSnapshot(
            provider: .cursor,
            planType: plan,
            primary: AccountUsageWindow(
                kind: .primary,
                usedPercent: primaryUsed,
                windowDurationMinutes: duration,
                resetsAt: end
            ),
            secondary: secondary,
            lifetimeTokens: nil,
            latestDailyTokens: nil,
            fetchedAt: fetchedAt
        )
    }

    /// Plan allowance first (`totalPercentUsed` or used/limit); then overall
    /// personal cap; then legacy request counts when present on the payload.
    static func primaryUsedPercent(from summary: CursorUsageSummaryDTO) -> Int? {
        if let total = summary.individualUsage?.plan?.totalPercentUsed,
           total.isFinite {
            return Int(min(100, max(0, total)).rounded())
        }
        if let plan = summary.individualUsage?.plan,
           let limit = plan.limit, limit > 0 {
            let used = Double(plan.used ?? 0)
            return Int(min(100, max(0, used / Double(limit) * 100)).rounded())
        }
        if let overall = summary.individualUsage?.overall,
           let limit = overall.limit, limit > 0 {
            let used = Double(overall.used ?? 0)
            return Int(min(100, max(0, used / Double(limit) * 100)).rounded())
        }
        if let gpt4 = summary.legacyGPT4,
           let limit = gpt4.maxRequestUsage, limit > 0 {
            let used = Double(gpt4.numRequests ?? gpt4.numRequestsTotal ?? 0)
            return Int(min(100, max(0, used / Double(limit) * 100)).rounded())
        }
        return nil
    }

    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }

    static func durationMinutes(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        return minutes > 0 ? minutes : nil
    }
}

// MARK: - Wire DTOs (redacted fixtures only; no live account fields required)

struct CursorUsageSummaryDTO: Decodable {
    var billingCycleStart: String?
    var billingCycleEnd: String?
    var membershipType: String?
    var individualUsage: CursorIndividualUsageDTO?
    /// Optional legacy `/api/usage` gpt-4 block when embedded in a fixture.
    var legacyGPT4: CursorLegacyModelUsageDTO?

    enum CodingKeys: String, CodingKey {
        case billingCycleStart, billingCycleEnd, membershipType, individualUsage
        case legacyGPT4 = "gpt-4"
    }
}

struct CursorIndividualUsageDTO: Decodable {
    var plan: CursorPlanUsageDTO?
    var onDemand: CursorOnDemandUsageDTO?
    var overall: CursorOnDemandUsageDTO?
}

struct CursorPlanUsageDTO: Decodable {
    var used: Int?
    var limit: Int?
    var remaining: Int?
    var totalPercentUsed: Double?
}

struct CursorOnDemandUsageDTO: Decodable {
    var used: Int?
    var limit: Int?
    var remaining: Int?
}

struct CursorLegacyModelUsageDTO: Decodable {
    var numRequests: Int?
    var numRequestsTotal: Int?
    var maxRequestUsage: Int?
}

/// Reads Cursor plan allowance via session Cookie + `usage-summary`.
/// Cookie may come from a pasted header (#104) or optional browser import (#105).
///
/// Cookie source mode is resolved on every `fetch()` (via `cookieMode`), so a
/// Settings Picker change takes effect on the next refresh without restarting.
public struct CursorUsageProvider: AccountUsageProviding {
    public static let defaultEndpoint = URL(string: "https://cursor.com/api/usage-summary")!

    private let cookie: String?
    private let cookieMode: @Sendable () -> CursorCookieSourceMode
    private let cookieImporter: CursorBrowserCookieImporting
    private let persistImportedCookie: @Sendable (String) -> Void
    private let endpoint: URL
    private let transport: CursorUsageTransport
    private let timeout: TimeInterval

    public init(
        cookie: String? = nil,
        cookieMode: @escaping @Sendable () -> CursorCookieSourceMode = { CursorCookieSourceSettings.mode() },
        cookieImporter: CursorBrowserCookieImporting = CursorBrowserCookieImporter(),
        persistImportedCookie: @escaping @Sendable (String) -> Void = { CursorSessionCookieStore.save($0) },
        endpoint: URL = defaultEndpoint,
        transport: CursorUsageTransport = URLSession.shared,
        timeout: TimeInterval = 15
    ) {
        self.cookie = cookie
        self.cookieMode = cookieMode
        self.cookieImporter = cookieImporter
        self.persistImportedCookie = persistImportedCookie
        self.endpoint = endpoint
        self.transport = transport
        self.timeout = timeout
    }

    public func fetch() async throws -> AccountUsageSnapshot {
        let cookie = try CursorCookieResolver.resolve(
            mode: cookieMode(),
            manualCookie: cookie,
            importer: cookieImporter,
            allowKeychainPrompt: false,
            persistImportedCookie: persistImportedCookie
        )
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("VibeBuddy", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.cursorData(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw AccountUsageError.timedOut
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw AccountUsageError.offline
        } catch {
            throw AccountUsageError.unknown
        }

        guard let http = response as? HTTPURLResponse else {
            throw AccountUsageError.unknown
        }
        switch http.statusCode {
        case 200:
            return try CursorUsageSummaryDecoder.decode(data, fetchedAt: Date())
        case 401, 403:
            throw AccountUsageError.notLoggedIn
        case 429:
            throw AccountUsageError.rateLimited
        default:
            throw AccountUsageError.providerUnavailable
        }
    }
}
