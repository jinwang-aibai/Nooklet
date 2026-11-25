import Darwin
import Foundation

public struct InterfaceAddress: Hashable, Sendable {
    public let interface: String
    public let address: String
    public let isIPv6: Bool
}

public enum IPAddresses {
    public static func local() throws -> [InterfaceAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { freeifaddrs(interfaces) }

        var addresses: Set<InterfaceAddress> = []
        var current = interfaces
        while let node = current {
            let entry = node.pointee
            current = entry.ifa_next
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                     &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            if status == 0 {
                let host = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                addresses.insert(InterfaceAddress(interface: String(cString: entry.ifa_name),
                                                  address: host, isIPv6: family == AF_INET6))
            }
        }
        return addresses.sorted {
            if $0.interface != $1.interface { return $0.interface.localizedStandardCompare($1.interface) == .orderedAscending }
            if $0.isIPv6 != $1.isIPv6 { return !$0.isIPv6 }
            return $0.address < $1.address
        }
    }

    public static func isIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty, !value.utf8.contains(0) else { return false }
        var v4 = in_addr()
        var v6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
}
