import SwiftUI
import UIKit
import VibeBuddyKit

/// The app that puts this phone on the tailnet. Official Tailscale is the
/// default path; Surge's Tailscale policy is the variant for people who
/// already route through Surge.
enum NetworkApp: String, CaseIterable, Identifiable {
    case tailscale, surge

    static let storageKey = "remote.networkApp"

    var id: String { rawValue }
    var name: String { self == .tailscale ? "Tailscale" : "Surge" }

    /// Surge's documented scheme starts the tunnel; Tailscale's opens the
    /// app, where the toggle is the first control.
    var openURL: URL { URL(string: self == .tailscale ? "tailscale://" : "surge:///start")! }

    @MainActor
    var isInstalled: Bool { UIApplication.shared.canOpenURL(openURL) }

    /// The person's saved choice while that app is still here; otherwise
    /// Surge only when it is the one installed, and Tailscale in every
    /// other case.
    @MainActor
    static func preferred(saved: String?) -> NetworkApp {
        let installed = allCases.filter(\.isInstalled)
        if let saved = saved.flatMap(NetworkApp.init(rawValue:)), installed.contains(saved) {
            return saved
        }
        return installed == [.surge] ? .surge : .tailscale
    }
}

/// The one tap that fixes a `tailnetOff`: open the VPN app that is here,
/// the one chosen or verified on the remote-setup page first. With both
/// installed and nothing saved, Surge goes first as it always has: turning
/// on Tailscale would push a working Surge tunnel off (iOS runs one VPN).
enum VPNAppOpener {
    /// Returns false when neither app is installed; the caller then shows
    /// the remote-setup page instead.
    @MainActor
    @discardableResult
    static func open() -> Bool {
        let saved = UserDefaults.standard.string(forKey: NetworkApp.storageKey).flatMap(NetworkApp.init(rawValue:))
        let order: [NetworkApp] = (saved.map { [$0] } ?? []) + [.surge, .tailscale]
        guard let app = order.first(where: \.isInstalled) else { return false }
        UIApplication.shared.open(app.openURL)
        return true
    }
}

/// Which link is missing, in one sentence, with the tap that fixes it when
/// one does (ADR-0032). Shared by the dashboard's empty state and *Device &
/// connection* so both name the same fault the same way.
struct ConnectionFailureCard: View {
    let reason: ConnectionFailureReason
    let macName: String?
    /// Where to go when no VPN app answers: the remote-setup page.
    var openSetup: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(ConnectionFailureCopy.title(reason, macName: macName),
                  systemImage: reason.needsTailnet ? "lock.shield" : "wifi.exclamationmark")
                .font(CompanionType.font(14, .semibold))
                .foregroundStyle(CompanionPalette.status(.error))
            Text(ConnectionFailureCopy.detail(reason))
                .font(CompanionType.font(13))
                .foregroundStyle(CompanionPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if reason.needsTailnet {
                Button {
                    if !VPNAppOpener.open() { openSetup() }
                } label: {
                    Label(ConnectionFailureCopy.vpnHint, systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .accessibilityIdentifier("connection-turn-on-vpn")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("connection-failure-card")
    }
}
