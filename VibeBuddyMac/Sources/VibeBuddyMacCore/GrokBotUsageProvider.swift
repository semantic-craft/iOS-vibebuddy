import Foundation
import VibeBuddyKit

/// Metadata-only read of the active official Grok Bot account's Sand allowance.
public struct GrokBotUsageProvider: AccountUsageProviding {
    private let account: @Sendable () async throws -> GrokBotLocalAccount
    private let activeIdentity: @Sendable () throws -> String
    private let transport: any CursorUsageTransport

    public init(
        account: @escaping @Sendable () async throws -> GrokBotLocalAccount = { try await GrokBotLocalAccount.load() },
        activeIdentity: @escaping @Sendable () throws -> String = { try GrokBotLocalAccount.activeIdentity() },
        transport: any CursorUsageTransport = URLSession.shared
    ) {
        self.account = account
        self.activeIdentity = activeIdentity
        self.transport = transport
    }

    public func acceptsCachedSnapshot(_ snapshot: AccountUsageSnapshot) -> Bool {
        guard let identity = snapshot.accountIdentity else { return false }
        return (try? activeIdentity()) == identity
    }

    public func fetch() async throws -> AccountUsageSnapshot {
        do {
            let identity = try await account()
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!)
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 15
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
            request.setValue("0.44.0", forHTTPHeaderField: "x-cursor-client-version")
            request.setValue("prod", forHTTPHeaderField: "x-sand-box-namespace")
            request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
            if let team = identity.teamID { request.setValue(team, forHTTPHeaderField: "x-cursor-team-id") }
            let (data, response) = try await transport.cursorData(for: request)
            try Task.checkCancellation()
            guard try activeIdentity() == identity.accountIdentity else { throw AccountUsageError.notLoggedIn }
            guard let http = response as? HTTPURLResponse else { throw AccountUsageError.unknown }
            switch http.statusCode {
            case 200:
                var sample = try GrokBotUsageDecoder.decode(data, fetchedAt: Date())
                sample.accountLabel = identity.accountLabel
                sample.accountIdentity = identity.accountIdentity
                return sample
            case 401, 403: throw AccountUsageError.notLoggedIn
            case 429: throw AccountUsageError.rateLimited
            default: throw AccountUsageError.providerUnavailable
            }
        } catch is CancellationError { throw CancellationError()
        } catch let error as AccountUsageError { throw error
        } catch let error as URLError {
            throw error.code == .timedOut ? AccountUsageError.timedOut : AccountUsageError.offline
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw AccountUsageError.notLoggedIn
        } catch { throw AccountUsageError.unknown }
    }
}

public enum GrokBotUsageDecoder {
    private struct Response: Decodable {
        let usagePercent: Double?
        let hasAvailableUsage: Bool?
        let nextResetTimestampUtc: String?
        let includedLimitZero: Bool?
        let usesPooledEnterpriseAllowance: Bool?
        let grokPlanLabel: String?
    }

    public static func decode(_ data: Data, fetchedAt: Date) throws -> AccountUsageSnapshot {
        guard let value = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AccountUsageError.incompatibleFormat
        }
        let reset = CursorUsageSummaryDecoder.parseTimestamp(value.nextResetTimestampUtc)
        var snapshot = AccountUsageSnapshot(provider: .grokBot, planType: value.grokPlanLabel,
            primary: nil, secondary: nil, lifetimeTokens: nil, latestDailyTokens: nil,
            fetchedAt: fetchedAt, periodEnd: reset)
        snapshot.hasAvailableUsage = value.hasAvailableUsage
        if value.usesPooledEnterpriseAllowance == true {
            snapshot.usageDetail = "Shared enterprise allowance; personal percentage unavailable"
        } else if value.includedLimitZero == true {
            snapshot.usageDetail = "No included allowance; personal percentage unavailable"
        } else if let percent = value.usagePercent {
            guard percent.isFinite, (0...100).contains(percent), let reset, reset > fetchedAt else {
                throw AccountUsageError.incompatibleFormat
            }
            snapshot.primary = AccountUsageWindow(kind: .primary, usedPercent: Int(percent.rounded()),
                windowDurationMinutes: 10_080, resetsAt: reset, label: "Weekly allowance")
        } else {
            snapshot.usageDetail = "Weekly percentage unavailable"
        }
        return snapshot
    }
}
