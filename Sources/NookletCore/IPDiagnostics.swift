import Darwin
import Foundation

public struct ConnectivityTarget: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let url: URL

    public init?(name: String, address: String, id: String = UUID().uuidString) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !address.isEmpty, address.utf8.count <= 2048,
              let parts = URLComponents(string: address.contains("://") ? address : "https://" + address),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, let url = parts.url else { return nil }
        self.id = id
        self.name = name
        self.url = url
    }
}

public enum WebRTCMatch: Equatable, Sendable {
    case matches
    case different
    case unverified
}

extension IPAddresses {
    public static func webRTCMatch(_ candidate: String, with exits: [String]) -> WebRTCMatch {
        guard let address = normalizedPublic(candidate) else { return .unverified }
        let references = exits.compactMap(normalizedPublic).filter { $0.contains(":") == address.contains(":") }
        if references.contains(address) { return .matches }
        return references.isEmpty ? .unverified : .different
    }

    /// Canonical globally routable addresses used for comparing independent probes.
    public static func normalizedPublic(_ input: String) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIPAddress(text) else { return nil }
        var ipv4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return publicIPv4(withUnsafeBytes(of: &ipv4) { Array($0) })
        }

        var ipv6 = in6_addr()
        guard text.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return publicIPv4(Array(bytes.suffix(4)))
        }
        guard bytes[0] & 0xe0 == 0x20, !bytes.starts(with: [0x20, 0x01, 0x0d, 0xb8]),
              !bytes.starts(with: [0x3f, 0xff]) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func publicIPv4(_ bytes: [UInt8]) -> String? {
        let a = bytes[0], b = bytes[1], c = bytes[2]
        switch a {
        case 0, 10, 127, 224...255: return nil
        case 100 where (64...127).contains(b): return nil
        case 169 where b == 254: return nil
        case 172 where (16...31).contains(b): return nil
        case 192 where b == 168 || (b == 0 && [0, 2].contains(c)): return nil
        case 198 where b == 18 || b == 19 || (b == 51 && c == 100): return nil
        case 203 where b == 0 && c == 113: return nil
        default: return bytes.map(String.init).joined(separator: ".")
        }
    }
}
