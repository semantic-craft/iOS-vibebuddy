import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds the Mac's LAN IPv4 to put in the pairing QR.
public enum LANAddress {

    /// Pure picker (unit-tested): prefer `en*` interfaces, skip loopback and
    /// link-local; fall back to the first usable address.
    public static func pick(from candidates: [(name: String, ip: String)]) -> String? {
        let usable = candidates.filter {
            !$0.ip.isEmpty && !$0.ip.hasPrefix("127.") && !$0.ip.hasPrefix("169.254.")
        }
        return usable.first(where: { $0.name.hasPrefix("en") })?.ip ?? usable.first?.ip
    }

    /// Enumerate live IPv4 interfaces and pick the primary one.
    public static func primaryIPv4() -> String? {
        var candidates: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var cursor = ifaddr
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET),
                  (Int32(ptr.pointee.ifa_flags) & IFF_UP) == IFF_UP
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                           &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                candidates.append((String(cString: ptr.pointee.ifa_name), String(cString: host)))
            }
        }
        return pick(from: candidates)
    }
}
