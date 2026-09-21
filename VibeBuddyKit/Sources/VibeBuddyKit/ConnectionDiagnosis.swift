import Foundation

/// Why the phone cannot talk to the Mac right now, as far as the phone can
/// honestly tell.
///
/// "Disconnected" was the only word the phone had, and on 2026-09-22 it was
/// the wrong one four times in a row: the Mac was up, the pairing was fine,
/// and the only thing missing was the tailnet on the phone (Surge stopped).
/// Every approval tapped on the Watch that night was dropped without a word.
/// This enum is the vocabulary for saying which link is missing, and the
/// hint that goes with it. It is derived from three facts the phone already
/// has — the pairing's host, the transport error, and whether a tailnet
/// address is configured on this phone — and never from a guess.
public enum ConnectionFailureReason: Equatable, Sendable, Codable {
    /// The pairing points at a tailnet address (`100.64.0.0/10` or `*.ts.net`)
    /// and this phone has no tailnet address of its own: Surge / Tailscale is
    /// not running here, so the Mac's address cannot be routed at all.
    case tailnetOff(host: String)
    /// The address is routable but nothing answered: the Mac is off, asleep,
    /// the app is not running, or a firewall is in the way.
    case macUnreachable(host: String)
    /// The Mac answered and refused the bearer.
    case authentication
    /// The saved address is not a usable endpoint.
    case invalidAddress
    /// The link was there and went away; reconnecting.
    case dropped

    /// Whether a wrist or banner action could be delivered right now. Only a
    /// bad address or a refused token make retrying pointless; everything else
    /// is a matter of the link coming back.
    public var isRetryable: Bool {
        switch self {
        case .tailnetOff, .macUnreachable, .dropped: return true
        case .authentication, .invalidAddress: return false
        }
    }

    /// The host this reason is about, when it names one.
    public var host: String? {
        switch self {
        case .tailnetOff(let host), .macUnreachable(let host): return host
        case .authentication, .invalidAddress, .dropped: return nil
        }
    }

    /// Whether turning the phone's VPN app on is the one thing that fixes this.
    public var needsTailnet: Bool {
        if case .tailnetOff = self { return true }
        return false
    }
}

/// The shape of a transport failure, independent of Foundation's error types
/// so the rule can be tested without a network.
public enum ConnectionFailureKind: Equatable, Sendable {
    /// Connection refused, no route, host not found, request timed out.
    case unreachable
    /// The socket was open and closed on us.
    case dropped
    case authentication
    case invalidAddress
}

public enum ConnectionDiagnosis {
    /// Name the innermost missing link.
    ///
    /// - Parameters:
    ///   - endpoint: The Mac's address as paired.
    ///   - kind: What the transport reported.
    ///   - phoneHasTailnet: Whether this phone currently holds an address in
    ///     the tailnet range on any interface — the one thing a running Surge
    ///     or Tailscale gives it and a stopped one takes away.
    public static func diagnose(endpoint: CompanionEndpoint?, kind: ConnectionFailureKind,
                                phoneHasTailnet: Bool) -> ConnectionFailureReason {
        switch kind {
        case .authentication: return .authentication
        case .invalidAddress: return .invalidAddress
        case .dropped:
            guard let endpoint else { return .dropped }
            // A tailnet pairing whose tunnel is gone drops the socket first
            // and refuses the reconnect second; say the real reason at once.
            return endpoint.isTailscale && !phoneHasTailnet ? .tailnetOff(host: endpoint.host) : .dropped
        case .unreachable:
            guard let endpoint else { return .invalidAddress }
            if endpoint.isTailscale && !phoneHasTailnet { return .tailnetOff(host: endpoint.host) }
            return .macUnreachable(host: endpoint.host)
        }
    }
}

/// What the phone found when it probed the Mac's unauthenticated `/health`.
public enum ReachabilityProbe: Equatable, Sendable {
    case reachable
    case unreachable(ConnectionFailureReason)
}
