import Darwin
import Foundation
import VibeBuddyKit

/// What this phone's own interfaces say about the tailnet.
///
/// Surge and Tailscale both give the phone an address in `100.64.0.0/10` on a
/// `utun` interface while they run, and take it away when they stop. That
/// address is the one fact that separates "the Mac is down" from "this phone
/// has no road to the Mac" — the difference between walking to the Mac and
/// tapping a VPN toggle. Read live on every failure, never cached: the toggle
/// is what changes it.
enum PhoneNetwork {
    /// Whether any interface on this phone currently carries a tailnet IPv4.
    static func hasTailnetAddress() -> Bool {
        addresses().contains { CompanionEndpoint(host: $0, port: 1)?.isTailnetIPv4 == true }
    }

    /// Every IPv4 address on an interface that is up and running.
    static func addresses() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append(String(cString: buffer))
        }
        return found
    }
}
