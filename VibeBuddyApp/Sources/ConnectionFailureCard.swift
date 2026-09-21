import SwiftUI
import UIKit
import VibeBuddyKit

/// The one tap that fixes a `tailnetOff`: open the VPN app that is here.
enum VPNAppOpener {
    /// Surge's documented scheme starts the tunnel; Tailscale's opens the
    /// app, where the toggle is the first control.
    static let candidates: [URL] = [URL(string: "surge:///start")!, URL(string: "tailscale://")!]

    /// Whether either app answers to its scheme on this phone.
    @MainActor
    static var isAvailable: Bool {
        candidates.contains { UIApplication.shared.canOpenURL($0) }
    }

    /// Returns false when neither app is installed; the caller then shows
    /// the remote-setup page instead.
    @MainActor
    @discardableResult
    static func open() -> Bool {
        guard let url = candidates.first(where: { UIApplication.shared.canOpenURL($0) }) else { return false }
        UIApplication.shared.open(url)
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
