import Foundation
import Darwin

public final class NetworkManager: Sendable {
    public static let shared = NetworkManager()

    public init() {}

    /// Retrieves all active non-loopback IPv4 addresses on this Mac.
    public static func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return []
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)

            // Check if interface is UP and running, not loopback
            if (flags & (IFF_UP | IFF_RUNNING)) != 0 && (flags & IFF_LOOPBACK) == 0 {
                guard let address = interface.ifa_addr else {
                    ptr = current.pointee.ifa_next
                    continue
                }
                let family = address.pointee.sa_family
                if family == UInt8(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        address,
                        socklen_t(address.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ipBytes = hostname.map { UInt8(bitPattern: $0) }
                        let ip = String(decoding: ipBytes.prefix { $0 != 0 }, as: UTF8.self)
                        // Ignore link-local auto-ip
                        if !ip.hasPrefix("169.254.") && ip != "127.0.0.1" {
                            let name = String(cString: interface.ifa_name)
                            // Put en0 (usually Wi-Fi) at the front
                            if name == "en0" {
                                addresses.insert(ip, at: 0)
                            } else {
                                addresses.append(ip)
                            }
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }

        return addresses
    }

    /// Gets primary LAN IPv4 address (e.g. Wi-Fi IP), or nil if disconnected.
    public static func getPrimaryLANIP() -> String? {
        getLocalIPAddresses().first
    }

    /// Formats the reachable LAN URL given IP and port.
    public static func formatServiceURL(ip: String?, port: Int) -> String {
        guard let ip = ip, !ip.isEmpty else {
            return "未连接局域网"
        }
        return "http://\(ip):\(port)"
    }

    /// Formats host:port string convenient for inputting into the iOS app.
    public static func formatHostPort(ip: String?, port: Int) -> String {
        guard let ip = ip, !ip.isEmpty else {
            return "127.0.0.1:\(port)"
        }
        return "\(ip):\(port)"
    }
}
